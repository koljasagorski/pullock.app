import Foundation
import IOKit
import IOKit.usb

public struct USBWatcherFailure: Error, Equatable, Sendable {
    public let operation: String
    public let code: Int32?
    public init(_ operation: String, code: Int32? = nil) { self.operation = operation; self.code = code }
}

public enum USBWatcherEvent: Sendable {
    case ready(watcher: UUID, inventory: [USBDevice])
    case attached(USBDevice)
    case removed(instance: UInt64, cached: USBDevice?)
    case reconciled([USBDevice])
    case failed(USBWatcherFailure)
    case stopped
}

/// Read-only physical USB observation. Main-actor isolation also works in a
/// headless process; it is not coupled to any window or SwiftUI lifetime.
@MainActor
public final class USBWatcher {
    public private(set) var watcherID = UUID()
    public private(set) var running = false
    public private(set) var ready = false
    public private(set) var failure: USBWatcherFailure?
    private var port: IONotificationPortRef?
    private var attachIterator: io_iterator_t = 0
    private var removeIterator: io_iterator_t = 0
    private var devices: [UInt64: USBDevice] = [:]
    private let onEvent: @MainActor (USBWatcherEvent) -> Void

    public var inventory: [USBDevice] { devices.values.sorted { $0.instance < $1.instance } }

    public init(onEvent: @escaping @MainActor (USBWatcherEvent) -> Void) { self.onEvent = onEvent }

    isolated deinit { close() }

    public func start() throws {
        guard !running else { return }
        watcherID = UUID()
        failure = nil
        ready = false
        devices.removeAll()
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            let reason = USBWatcherFailure("create_notification_port")
            fail(reason)
            throw reason
        }
        self.port = port
        running = true
        IONotificationPortSetDispatchQueue(port, .main)
        let context = Unmanaged.passUnretained(self).toOpaque()
        do {
            let attachStatus = IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, try matching(),
                { context, iterator in
                    guard let context else { return }
                    MainActor.assumeIsolated {
                        Unmanaged<USBWatcher>.fromOpaque(context).takeUnretainedValue().drain(iterator, attached: true)
                    }
                }, context, &attachIterator)
            guard attachStatus == KERN_SUCCESS else { throw USBWatcherFailure("register_attach", code: attachStatus) }
            drain(attachIterator, attached: true)
            let removeStatus = IOServiceAddMatchingNotification(port, kIOTerminatedNotification, try matching(),
                { context, iterator in
                    guard let context else { return }
                    MainActor.assumeIsolated {
                        Unmanaged<USBWatcher>.fromOpaque(context).takeUnretainedValue().drain(iterator, attached: false)
                    }
                }, context, &removeIterator)
            guard removeStatus == KERN_SUCCESS else { throw USBWatcherFailure("register_termination", code: removeStatus) }
            drain(removeIterator, attached: false)
            try reconcile(emit: false)
            if let failure { throw failure }
            ready = true
            onEvent(.ready(watcher: watcherID, inventory: inventory))
        } catch {
            close()
            let reason = (error as? USBWatcherFailure) ?? USBWatcherFailure("unexpected_start_failure")
            fail(reason)
            throw reason
        }
    }

    /// Explicit bootstrap/wake/recovery reconciliation, not periodic USB polling.
    public func reconcile() throws {
        guard running else { throw USBWatcherFailure("watcher_not_running") }
        if let failure { throw failure }
        do { try reconcile(emit: true) }
        catch {
            let reason = (error as? USBWatcherFailure) ?? USBWatcherFailure("unexpected_snapshot_failure")
            fail(reason)
            throw reason
        }
    }

    public func stop() {
        let wasRunning = running
        close()
        if wasRunning { onEvent(.stopped) }
    }

    private func close() {
        running = false
        ready = false
        if attachIterator != 0 { IOObjectRelease(attachIterator); attachIterator = 0 }
        if removeIterator != 0 { IOObjectRelease(removeIterator); removeIterator = 0 }
        if let port { IONotificationPortDestroy(port); self.port = nil }
        devices.removeAll()
    }

    private func matching() throws -> CFMutableDictionary {
        guard let dictionary = IOServiceMatching("IOUSBHostDevice") else {
            throw USBWatcherFailure("create_matching_dictionary")
        }
        (dictionary as NSMutableDictionary)[kIOPropertyMatchKey] = [kUSBVendorID: NSNumber(value: 0x1050)]
        return dictionary
    }

    private func read(_ service: io_service_t) throws -> USBDevice {
        var id: UInt64 = 0
        let status = IORegistryEntryGetRegistryEntryID(service, &id)
        guard status == KERN_SUCCESS else { throw USBWatcherFailure("registry_id", code: status) }
        var properties: [String: Any] = [:]
        for key in USBDescriptorParser.propertyKeys {
            properties[key] = IORegistryEntryCreateCFProperty(service, key as CFString,
                kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        do { return try USBDescriptorParser.parse(instance: id, properties: properties) }
        catch { throw USBWatcherFailure("invalid_device_descriptor") }
    }

    private func drain(_ iterator: io_iterator_t, attached: Bool) {
        guard running, iterator != 0,
              iterator == (attached ? attachIterator : removeIterator) else { return }
        while running, case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            do {
                if attached {
                    let device = try read(service)
                    guard devices[device.instance] == nil else { continue }
                    guard devices.count < 128 else { throw USBWatcherFailure("inventory_limit") }
                    devices[device.instance] = device
                    if ready { onEvent(.attached(device)) }
                } else {
                    var id: UInt64 = 0
                    let result = IORegistryEntryGetRegistryEntryID(service, &id)
                    guard result == KERN_SUCCESS else { throw USBWatcherFailure("termination_registry_id", code: result) }
                    let cached = devices.removeValue(forKey: id)
                    if ready { onEvent(.removed(instance: id, cached: cached)) }
                }
            } catch {
                fail((error as? USBWatcherFailure) ?? USBWatcherFailure("unexpected_callback_failure"))
            }
        }
        if running, IOIteratorIsValid(iterator) == 0 { fail(USBWatcherFailure("notification_iterator_invalid")) }
    }

    private func reconcile(emit: Bool) throws {
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, try matching(), &iterator)
        guard result == KERN_SUCCESS else { throw USBWatcherFailure("enumerate_devices", code: result) }
        defer { if iterator != 0 { IOObjectRelease(iterator) } }
        var snapshot: [UInt64: USBDevice] = [:]
        while iterator != 0, case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            let device = try read(service)
            guard snapshot.count < 128 else { throw USBWatcherFailure("inventory_limit") }
            snapshot[device.instance] = device
        }
        guard iterator == 0 || IOIteratorIsValid(iterator) != 0 else {
            throw USBWatcherFailure("snapshot_iterator_invalid")
        }
        devices = snapshot
        if emit { onEvent(.reconciled(inventory)) }
    }

    private func fail(_ reason: USBWatcherFailure) {
        ready = false
        let firstFailure = failure == nil
        failure = reason
        if firstFailure { onEvent(.failed(reason)) }
    }
}
