import DaemonPowerMessages
import Foundation
import IOKit
import IOKit.pwr_mgt
import PullockCore
import PullockIPC
import PullockServices
import PullockUSB
import SystemConfiguration

/// The development daemon now owns USB and power observation. Live action
/// capabilities stay unavailable; no input-event or shutdown adapter is linked.
@MainActor
public final class NativeDaemonRuntime {
    public nonisolated let bootID: UUID
    private nonisolated let cache: SnapshotCache
    private nonisolated let handoff = MainActorHandoff()
    private let coordinator: DaemonCoordinator
    private let usb: NativeUSBSource
    private let power: NativePowerSource
    private let console: NativeConsoleSource
    private var timer: DispatchSourceTimer?
    private var started = false
    private var stopped = false

    public init() throws {
        let usb = NativeUSBSource()
        let coordinator = try DaemonCoordinator(readInventory: { try usb.read() },
            validateOwner: { try DiagnosticConsoleAccess.owner(effectiveUID: $0, auditSession: $1) })
        self.usb = usb; self.coordinator = coordinator
        bootID = coordinator.bootID; cache = coordinator.cache
        power = NativePowerSource { [weak coordinator] event in coordinator?.lifecycle(event) }
        console = NativeConsoleSource { [weak coordinator] in coordinator?.recheckOwner() }
        usb.event = { [weak coordinator] event in
            switch event {
            case .ready: coordinator?.watcherStarted()
            case .attached: coordinator?.inventoryChanged()
            case let .removed(instance, _): coordinator?.removed(instance)
            case .failed, .stopped: coordinator?.observationFailed()
            case .reconciled: break // Only explicit, epoch-bound reads publish inventory.
            }
        }
    }

    isolated deinit { stop() }

    public func start() throws {
        guard !started, !stopped else { throw DaemonRuntimeError.stopped }
        do {
            // Sleep acknowledgements must be installed before observing USB.
            try power.start(); try console.start(); try usb.start()
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now(), repeating: .milliseconds(250))
            timer.setEventHandler { [weak coordinator] in
                MainActor.assumeIsolated { coordinator?.pulse() }
            }
            self.timer = timer; timer.activate(); started = true
        } catch { stop(); throw error }
    }

    public func stop() {
        guard !stopped else { return }
        stopped = true
        timer?.cancel(); timer = nil
        usb.stop(); console.stop(); power.stop(); coordinator.stop()
    }

    public nonisolated func snapshot() -> StateSnapshot { cache.load() }
    public var observedDeviceCount: Int { usb.count }

    public nonisolated var commandHandler: ServiceCommandHandler {
        let coordinator = self.coordinator, handoff = self.handoff
        return { peer, payload, receivedAt in
            // NSXPC credentials were read synchronously on its callback queue.
            // The coordinator rechecks owner/session and expiry after this hop.
            let transaction = { @MainActor @Sendable in
                try coordinator.command(role: peer.role, uid: peer.owner.uid,
                    session: peer.owner.auditSession, receivedAt: receivedAt, payload: payload)
            }
            if Thread.isMainThread { return try MainActor.assumeIsolated { try transaction() } }
            return try handoff.perform(transaction)
        }
    }
}

@MainActor
private final class NativeUSBSource {
    var event: (@MainActor (USBWatcherEvent) -> Void)?
    private var reconciling = false
    private lazy var watcher = USBWatcher(scope: .allDevices) { [weak self] event in
        guard let self, !reconciling else { return }
        self.event?(event)
    }
    func start() throws { try watcher.start() }
    func stop() { watcher.stop() }
    var count: Int { watcher.inventory.count }
    func read() throws -> [WireDevice] {
        guard watcher.running, watcher.ready else { throw DaemonRuntimeError.observationUnavailable }
        reconciling = true
        defer { reconciling = false }
        try watcher.reconcile()
        return watcher.inventory.map {
            WireDevice(instance: $0.instance, vendorID: $0.vendorID, productID: $0.productID, name: $0.displayName)
        }
    }
}

@MainActor
private final class NativePowerSource {
    private var port: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var connection: io_connect_t = 0
    private let event: @MainActor (ProtectionEvent) -> Void
    init(event: @escaping @MainActor (ProtectionEvent) -> Void) { self.event = event }
    isolated deinit { stop() }

    func start() throws {
        connection = IORegisterForSystemPower(Unmanaged.passUnretained(self).toOpaque(), &port,
            { context, _, type, argument in
                guard let context else { return }
                MainActor.assumeIsolated {
                    Unmanaged<NativePowerSource>.fromOpaque(context).takeUnretainedValue().receive(type, argument)
                }
            }, &notifier)
        guard connection != 0, let port else { stop(); throw DaemonRuntimeError.powerRegistration }
        IONotificationPortSetDispatchQueue(port, .main)
    }

    private func receive(_ type: UInt32, _ argument: UnsafeMutableRawPointer?) {
        // Acknowledge before reducer/IO work. Pullock never vetoes sleep.
        if type == PLDaemonCanSleep || type == PLDaemonWillSleep {
            guard IOAllowPowerChange(connection, Int(bitPattern: argument)) == KERN_SUCCESS else {
                event(.watcherRestarted); return
            }
        }
        switch type {
        case PLDaemonWillSleep: event(.willSleep)
        case PLDaemonWillWake: event(.willWake)
        case PLDaemonDidWake: event(.didWake)
        default: break
        }
    }

    func stop() {
        if notifier != 0 { IODeregisterForSystemPower(&notifier); notifier = 0 }
        if let port { IONotificationPortDestroy(port); self.port = nil }
        if connection != 0 { IOServiceClose(connection); connection = 0 }
    }
}

@MainActor
private final class NativeConsoleSource {
    private var store: SCDynamicStore?
    private let changed: @MainActor () -> Void
    init(changed: @escaping @MainActor () -> Void) { self.changed = changed }
    isolated deinit { stop() }
    func start() throws {
        var context = SCDynamicStoreContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        guard let store = SCDynamicStoreCreate(nil, "Pullock daemon console" as CFString,
            { _, _, context in
                guard let context else { return }
                MainActor.assumeIsolated {
                    Unmanaged<NativeConsoleSource>.fromOpaque(context).takeUnretainedValue().changed()
                }
            }, &context),
            SCDynamicStoreSetNotificationKeys(store, [SCDynamicStoreKeyCreateConsoleUser(nil)] as CFArray, nil),
            SCDynamicStoreSetDispatchQueue(store, .main) else { throw DaemonRuntimeError.sessionRegistration }
        self.store = store
    }
    func stop() {
        if let store { SCDynamicStoreSetDispatchQueue(store, nil); self.store = nil }
    }
}
