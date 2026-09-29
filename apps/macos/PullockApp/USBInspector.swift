import AppKit
import Foundation
import Observation
import PullockUSB
import SwiftUI

@MainActor
@Observable
final class USBInspector {
    private(set) var devices: [USBDevice] = []
    private(set) var status = "Observation stopped"
    private(set) var ready = false
    private(set) var lastEvent: Date?
    private(set) var attachedCount = 0
    private(set) var removedCount = 0
    @ObservationIgnored private var redactor = ReportRedactor()
    @ObservationIgnored private var watcher: USBWatcher?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var visible = false
    @ObservationIgnored private var sleeping = false
    @ObservationIgnored private var active = true

    func start() {
        guard !visible else { return }
        visible = true
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.workspace(name) }
            })
        }
        beginObservation()
    }

    func stop() {
        visible = false
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        endObservation()
    }

    func restart() {
        endObservation()
        if visible && !sleeping && active { beginObservation() }
    }

    func token(for device: USBDevice) -> String {
        String(redactor.token(domain: "instance", value: String(device.instance)).prefix(8))
    }

    func reason(for device: USBDevice) -> String {
        switch EnrollmentReview.blocker(candidate: device.instance, inventory: devices, qualifiedProfiles: []) {
        case .missingSerial: "No passive USB serial number. Persistent registration is unavailable."
        case .invalidSerial: "The USB serial number is malformed. Registration is unavailable."
        case .conflictingSerial: "USB properties report conflicting serial numbers. Registration is unavailable."
        case .duplicateIdentity: "Multiple connected devices report the same identity. Registration is unavailable."
        case .unqualifiedProfile: "A serial number is visible, but this hardware profile has not been qualified."
        default: "Device identity has not been qualified for registration."
        }
    }

    private func beginObservation() {
        redactor = ReportRedactor()
        attachedCount = 0; removedCount = 0
        let watcher = USBWatcher { [weak self] event in self?.receive(event) }
        self.watcher = watcher
        do { try watcher.start() }
        catch { ready = false; devices = []; status = "USB observation failed. Restart to retry." }
    }

    private func endObservation() {
        watcher?.stop()
        watcher = nil
        devices = []; ready = false
        status = "Observation stopped"
    }

    private func receive(_ event: USBWatcherEvent) {
        lastEvent = Date()
        switch event {
        case let .ready(_, inventory):
            devices = inventory; ready = true; status = "Passive USB observation active"
        case .attached:
            attachedCount += 1; devices = watcher?.inventory ?? []
        case .removed:
            removedCount += 1; devices = watcher?.inventory ?? []
        case let .reconciled(inventory): devices = inventory
        case .failed:
            ready = false; devices = []; status = "USB observation failed. Restart to retry."
        case .stopped: ready = false; devices = []
        }
    }

    private func workspace(_ name: Notification.Name) {
        switch name {
        case NSWorkspace.willSleepNotification: sleeping = true
        case NSWorkspace.didWakeNotification: sleeping = false
        case NSWorkspace.sessionDidResignActiveNotification: active = false
        case NSWorkspace.sessionDidBecomeActiveNotification: active = true
        default: return
        }
        endObservation()
        if visible && !sleeping && active { beginObservation() }
        else { status = "Observation paused for sleep or session change" }
    }
}

struct USBInspectorView: View {
    @State private var inspector = USBInspector()
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text("DEVELOPMENT · NO PROTECTION").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text("Connected security keys").font(.largeTitle.weight(.semibold))
                Text("Inspect the USB properties macOS provides. This app cannot lock or shut down your Mac.")
                    .foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Label(inspector.status, systemImage: inspector.ready ? "cable.connector" : "exclamationmark.triangle")
                Spacer()
                Button("Restart observation") { inspector.restart() }
            }
            ScrollView {
                if inspector.devices.isEmpty {
                    ContentUnavailableView(inspector.ready ? "No Yubico USB device visible" : "No current device inventory",
                        systemImage: "key.horizontal", description: Text("Connect your key and allow the accessory in macOS if prompted."))
                        .frame(maxWidth: .infinity, minHeight: 180)
                }
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(inspector.devices, id: \.instance) { device in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Yubico USB device").font(.headline)
                                Text(String(format: "USB %04X:%04X · Instance %@", device.vendorID, device.productID, inspector.token(for: device)))
                                    .font(.callout.monospaced()).foregroundStyle(.secondary)
                                Text(inspector.reason(for: device)).fixedSize(horizontal: false, vertical: true)
                                Text("Not registered").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        }
                    }
                }
            }
            HStack(spacing: 20) {
                Text("Since observation started: \(inspector.attachedCount) attached · \(inspector.removedCount) removed")
                Spacer()
                if let date = inspector.lastEvent {
                    Text("Last event \(date.formatted(date: .omitted, time: .standard))")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                Text("No device commands or configuration changes. Instance labels change when observation restarts.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Open simulations") { openWindow(id: "simulation") }
            }
        }
        .padding(28)
        .onAppear { inspector.start() }
        .onDisappear { inspector.stop() }
    }
}
