import AppKit
import CoreGraphics
import Darwin
import IOKit
import IOKit.pwr_mgt
import ProbeSupport
import PullockUSB
import PowerMessagesC

/// C callbacks are delivered on DispatchQueue.main, including initial drains.
/// Lifetime: the entry point retains this object until stop() cancels all sources.
@MainActor
final class NativeProbe {
    private let trace: Trace
    private let redactor = ReportRedactor()
    private lazy var usb = USBWatcher { [weak self] event in self?.usbEvent(event) }
    private var powerPort: IONotificationPortRef?
    private var powerNotifier: io_object_t = 0
    private var powerConnection: io_connect_t = 0
    private var observers: [NSObjectProtocol] = []
    private var mock = MockRemovalProbe()
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

        observeWorkspace()
        recordSession()
        try usb.start()
        recordInventory(reason: "bootstrap")
        trace.record("usb", "observers_ready", ["candidate_count": String(usb.inventory.count),
            "protection": "unavailable", "actions": "mock_only"])
    }

    private func usbEvent(_ event: USBWatcherEvent) {
        guard !stopped else { return }
        switch event {
        case let .attached(device):
            trace.record("usb", "attached", device.reportFields(using: redactor))
            if !sleeping && sessionActive && !shuttingDown { mock.observed(device.instance) }
        case let .removed(instance, cached):
            trace.record("usb", "terminated", cached?.reportFields(using: redactor) ?? [
                "instance_token": redactor.token(domain: "instance", value: String(instance)), "identity": "not_cached"])
            if mock.removed(instance) {
                trace.record("mock", "would_request_lock", ["executed": "false", "reason": "observed_instance_terminated",
                    "power_epoch": String(mock.powerEpoch), "physical_cause": "unknown"])
            }
        case let .failed(failure): report(failure)
        case .ready, .reconciled, .stopped: break
        }
    }

    private func reconcile(reason: String) throws {
        try usb.reconcile()
        guard usb.ready else { throw ProbeFailure("usb_watcher_not_ready") }
        recordInventory(reason: reason)
    }

    private func recordInventory(reason: String) {
        let devices = usb.inventory
        if !sleeping && sessionActive && !shuttingDown {
            mock.beginFreshObservation()
            for device in devices { mock.observed(device.instance) }
        } else { mock.invalidatePresence() }
        trace.record("usb", "reconciled", ["reason": reason, "candidate_count": String(devices.count),
            "presence": "observation_only", "power_epoch": String(mock.powerEpoch)])
        for device in devices { trace.record("usb", "candidate", device.reportFields(using: redactor)) }
        let tokens = devices.compactMap { $0.reportFields(using: redactor)["serial_token"] }
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
        else if let error = error as? USBWatcherFailure { trace.error(error.operation, code: error.code) }
        else { trace.error("unexpected_probe_error") }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        let candidateCount = usb.inventory.count
        usb.stop()
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
        trace.record("probe", "stopped", ["candidate_count": String(candidateCount),
            "simulated_locks": String(mock.simulatedLocks), "real_actions": "0",
            "complete": String(!trace.failed), "protection": "unavailable"])
    }
}

struct ProbeFailure: Error {
    let operation: String
    let code: Int32?
    init(_ operation: String, _ code: Int32? = nil) { self.operation = operation; self.code = code }
}
