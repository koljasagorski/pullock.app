import AppKit
import CoreGraphics
import Darwin
import IOKit
import IOKit.pwr_mgt
import IOKit.usb
import ProbeSupport
import PowerMessagesC

private struct DeviceEvidence {
    let registryID: UInt64
    let fields: [String: String]
}

/// C callbacks are delivered on DispatchQueue.main, including initial drains.
/// Lifetime: the entry point retains this object until stop() cancels all sources.
@MainActor
final class NativeProbe {
    private let trace: Trace
    private let redactor = ReportRedactor()
    private var usbPort: IONotificationPortRef?
    private var powerPort: IONotificationPortRef?
    private var attachedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0
    private var powerNotifier: io_object_t = 0
    private var powerConnection: io_connect_t = 0
    private var observers: [NSObjectProtocol] = []
    private var devices: [UInt64: DeviceEvidence] = [:]
    private var mock = MockRemovalProbe()
    private var bootstrapping = true
    private var sleeping = false
    private var sessionActive = false
    private var shuttingDown = false
    private var stopped = false

    init(trace: Trace) { self.trace = trace }

    func start() throws {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        // Register power first; this does not establish cross-source ordering.
        powerConnection = IORegisterForSystemPower(refcon, &powerPort, { refcon, _, type, argument in
            guard let refcon else { return }
            MainActor.assumeIsolated {
                Unmanaged<NativeProbe>.fromOpaque(refcon).takeUnretainedValue().power(type, argument)
            }
        }, &powerNotifier)
        guard powerConnection != 0, let powerPort else { throw ProbeFailure("register_power") }
        IONotificationPortSetDispatchQueue(powerPort, .main)
        trace.record("power", "registered")

        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            throw ProbeFailure("create_usb_notification_port")
        }
        usbPort = port
        IONotificationPortSetDispatchQueue(port, .main)
        var status = IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, try matching(),
            { refcon, iterator in
                guard let refcon else { return }
                MainActor.assumeIsolated {
                    Unmanaged<NativeProbe>.fromOpaque(refcon).takeUnretainedValue().drain(iterator, attached: true)
                }
            }, refcon, &attachedIterator)
        guard status == KERN_SUCCESS else { throw ProbeFailure("register_attach", status) }
        drain(attachedIterator, attached: true)
        status = IOServiceAddMatchingNotification(port, kIOTerminatedNotification, try matching(),
            { refcon, iterator in
                guard let refcon else { return }
                MainActor.assumeIsolated {
                    Unmanaged<NativeProbe>.fromOpaque(refcon).takeUnretainedValue().drain(iterator, attached: false)
                }
            }, refcon, &removedIterator)
        guard status == KERN_SUCCESS else { throw ProbeFailure("register_termination", status) }
        drain(removedIterator, attached: false)
        observeWorkspace()
        recordSession()
        try reconcile(reason: "bootstrap")
        bootstrapping = false
        trace.record("usb", "observers_ready", ["candidate_count": String(devices.count),
            "protection": "unavailable", "actions": "mock_only"])
    }

    private func matching() throws -> CFMutableDictionary {
        guard let dictionary = IOServiceMatching("IOUSBHostDevice") else {
            throw ProbeFailure("create_usb_matching_dictionary")
        }
        // Only Yubico physical device services; never enumerate HID/CCID interfaces.
        // IOUSBHostDevice requires registry property matching. A top-level
        // idVendor key returned zero matches on the M1 target despite presence.
        (dictionary as NSMutableDictionary)[kIOPropertyMatchKey] = [kUSBVendorID: NSNumber(value: 0x1050)]
        return dictionary
    }

    private func drain(_ iterator: io_iterator_t, attached: Bool) {
        guard !stopped else { return }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var id: UInt64 = 0
            let status = IORegistryEntryGetRegistryEntryID(service, &id)
            guard status == KERN_SUCCESS else { trace.error("registry_entry_id", code: status); continue }
            if attached {
                guard devices[id] == nil else { continue }
                guard devices.count < 128 else { trace.error("candidate_limit"); continue }
                guard let evidence = readDevice(service, id: id) else { continue }
                devices[id] = evidence
                trace.record("usb", "attached", evidence.fields.merging(["phase": bootstrapping ? "bootstrap" : "live"]) { a, _ in a })
                if !bootstrapping { mock.observed(id) }
            } else {
                // Terminated services may have no readable properties: use cached evidence only.
                let evidence = devices.removeValue(forKey: id)
                trace.record("usb", "terminated", evidence?.fields ?? ["instance_token": redactor.token(domain: "instance", value: String(id)), "identity": "not_cached"])
                if !bootstrapping, mock.removed(id) {
                    trace.record("mock", "would_request_lock", ["executed": "false", "reason": "observed_instance_terminated",
                        "power_epoch": String(mock.powerEpoch), "physical_cause": "unknown"])
                }
            }
        }
        if IOIteratorIsValid(iterator) == 0 { trace.error("notification_iterator_invalid") }
    }

    private func property(_ service: io_service_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private func readDevice(_ service: io_service_t, id: UInt64) -> DeviceEvidence? {
        guard let vendor = usbIdentifier(property(service, kUSBVendorID)), vendor == 0x1050,
              let product = usbIdentifier(property(service, kUSBProductID)) else {
            trace.error("invalid_usb_identifiers")
            return nil
        }
        // Host-family constant plus explicitly identified legacy registry alias.
        // Conflicting values reject identity evidence; no fallback masks a malformed value.
        let serialKeys = [kUSBHostDevicePropertySerialNumberString, "USB Serial Number"]
        var properties: [String: Any] = [:]
        for key in serialKeys { properties[key] = property(service, key) }
        let serial = SerialEvidence.read(properties, keys: serialKeys)
        var fields = redactor.fields(for: serial)
        fields["instance_token"] = redactor.token(domain: "instance", value: String(id))
        fields["vendor_id"] = String(format: "0x%04x", vendor)
        fields["product_id"] = String(format: "0x%04x", product)
        fields["transport"] = "USB"
        if let index = usbIdentifier(property(service, kUSBHostDevicePropertySerialNumberStringIndex)) {
            fields["serial_descriptor_index"] = String(index)
        }
        return DeviceEvidence(registryID: id, fields: fields)
    }

    private func reconcile(reason: String) throws {
        var iterator: io_iterator_t = 0
        let status = IOServiceGetMatchingServices(kIOMainPortDefault, try matching(), &iterator)
        guard status == KERN_SUCCESS else { throw ProbeFailure("enumerate_usb", status) }
        // The SDK explicitly allows success + IO_OBJECT_NULL for no matches.
        defer { if iterator != 0 { IOObjectRelease(iterator) } }
        var snapshot: [UInt64: DeviceEvidence] = [:]
        while iterator != 0, case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard snapshot.count < 128 else { trace.error("candidate_limit"); continue }
            var id: UInt64 = 0
            let result = IORegistryEntryGetRegistryEntryID(service, &id)
            guard result == KERN_SUCCESS else { trace.error("snapshot_registry_entry_id", code: result); continue }
            if let evidence = readDevice(service, id: id) { snapshot[id] = evidence }
        }
        guard iterator == 0 || IOIteratorIsValid(iterator) != 0 else {
            throw ProbeFailure("snapshot_iterator_invalid")
        }
        devices = snapshot
        if !sleeping && sessionActive && !shuttingDown {
            mock.beginFreshObservation()
            for id in devices.keys { mock.observed(id) }
        } else {
            mock.invalidatePresence()
        }
        trace.record("usb", "reconciled", ["reason": reason, "candidate_count": String(devices.count),
            "presence": "observation_only", "power_epoch": String(mock.powerEpoch)])
        for evidence in devices.values.sorted(by: { $0.registryID < $1.registryID }) {
            trace.record("usb", "candidate", evidence.fields)
        }
        let tokens = devices.values.compactMap { $0.fields["serial_token"] }
        if Set(tokens).count != tokens.count {
            trace.record("identity", "duplicate_serial", ["enrollment": "rejected"])
        }
    }

    private func power(_ type: UInt32, _ argument: UnsafeMutableRawPointer?) {
        guard !stopped else { return }
        // ACK BEFORE trace, enumeration, or any output. Never veto sleep.
        if type == PLCanSystemSleep || type == PLSystemWillSleep {
            let result = IOAllowPowerChange(powerConnection, Int(bitPattern: argument))
            if result != KERN_SUCCESS { trace.error("acknowledge_power", code: result) }
        }
        switch type {
        case PLCanSystemSleep: trace.record("power", "can_sleep_acknowledged")
        case PLSystemWillSleep:
            sleeping = true
            mock.invalidatePresence()
            trace.record("power", "will_sleep_acknowledged", ["power_epoch": String(mock.powerEpoch)])
        case PLSystemWillPowerOn:
            // No hardware/disk/GUI access during early wake.
            trace.record("power", "will_power_on")
        case PLSystemHasPoweredOn:
            sleeping = false
            trace.record("power", "has_powered_on")
            recordSession()
            do { try reconcile(reason: "wake") } catch { report(error) }
        case PLSystemWillNotSleep: trace.record("power", "will_not_sleep")
        default: trace.record("power", "other_message", ["type": String(type)])
        }
    }

    private func observeWorkspace() {
        let names: [(Notification.Name, String)] = [
            (NSWorkspace.sessionDidBecomeActiveNotification, "session_active"),
            (NSWorkspace.sessionDidResignActiveNotification, "session_inactive"),
            (NSWorkspace.willPowerOffNotification, "will_power_off"),
            (NSWorkspace.willSleepNotification, "workspace_will_sleep"),
            (NSWorkspace.didWakeNotification, "workspace_did_wake"),
            (NSWorkspace.screensDidSleepNotification, "display_sleep"),
            (NSWorkspace.screensDidWakeNotification, "display_wake"),
        ]
        let center = NSWorkspace.shared.notificationCenter
        for (name, event) in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.workspace(event) }
            })
        }
        trace.record("session", "observers_registered")
    }

    private func workspace(_ event: String) {
        guard !stopped else { return }
        trace.record("session", event)
        switch event {
        case "session_inactive", "will_power_off":
            sessionActive = false
            if event == "will_power_off" { shuttingDown = true }
            mock.invalidatePresence()
        case "session_active":
            recordSession()
            if !sleeping { do { try reconcile(reason: "session_active") } catch { report(error) } }
        default: break // Display sleep is not system sleep; workspace events are supplemental.
        }
    }

    private func recordSession() {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            sessionActive = false
            trace.record("session", "snapshot", ["gui_session": "unavailable", "lock_state": "unknown"])
            return
        }
        let onConsole = session[kCGSessionOnConsoleKey as String] as? Bool
        let loginDone = session[kCGSessionLoginDoneKey as String] as? Bool
        let uid = session[kCGSessionUserIDKey as String] as? NSNumber
        let ownerMatches = uid?.uint32Value == getuid()
        sessionActive = onConsole == true && loginDone == true && ownerMatches
        trace.record("session", "snapshot", ["gui_session": "available",
            "on_console": onConsole.map(String.init) ?? "unknown",
            "login_done": loginDone.map(String.init) ?? "unknown",
            "owner_matches_process": String(ownerMatches), "lock_state": "unknown"])
    }

    func report(_ error: Error) {
        mock.invalidatePresence()
        if let error = error as? ProbeFailure { trace.error(error.operation, code: error.code) }
        else { trace.error("unexpected_probe_error") }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        if attachedIterator != 0 { IOObjectRelease(attachedIterator); attachedIterator = 0 }
        if removedIterator != 0 { IOObjectRelease(removedIterator); removedIterator = 0 }
        if let usbPort { IONotificationPortDestroy(usbPort); self.usbPort = nil }
        if powerNotifier != 0 {
            let status = IODeregisterForSystemPower(&powerNotifier)
            if status != KERN_SUCCESS { trace.error("deregister_power", code: status) }
            powerNotifier = 0
        }
        if let powerPort { IONotificationPortDestroy(powerPort); self.powerPort = nil }
        if powerConnection != 0 {
            let status = IOServiceClose(powerConnection)
            if status != KERN_SUCCESS { trace.error("close_power_connection", code: status) }
            powerConnection = 0
        }
        trace.record("probe", "stopped", ["candidate_count": String(devices.count),
            "simulated_locks": String(mock.simulatedLocks), "real_actions": "0",
            "complete": String(!trace.failed), "protection": "unavailable"])
    }
}

struct ProbeFailure: Error {
    let operation: String
    let code: Int32?
    init(_ operation: String, _ code: Int32? = nil) { self.operation = operation; self.code = code }
}
