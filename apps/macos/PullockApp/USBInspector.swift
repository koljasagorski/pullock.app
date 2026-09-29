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
    private(set) var selection: ConnectionSelection?
    private(set) var selectionMessage = "Choose one connected USB device."
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
        selected(device) ? "Selected for this connection only. Protection is not active." : "Contents and serial number are not used for selection."
    }

    func selected(_ device: USBDevice) -> Bool {
        selection?.instance == device.instance && selection?.expired == false
    }

    func select(_ device: USBDevice) {
        guard let watcher, ready, !sleeping, active else { return }
        do {
            try watcher.reconcile()
            selection = try ConnectionSelection(instance: device.instance, inventory: watcher.inventory, watcherID: watcher.watcherID)
            selectionMessage = "USB connection selected. Reconnect, sleep or a session change clears the selection."
        } catch {
            selection = nil
            selectionMessage = "This connection is no longer available. Choose a currently connected device."
        }
    }

    private func beginObservation() {
        redactor = ReportRedactor()
        attachedCount = 0; removedCount = 0
        let watcher = USBWatcher(scope: .allDevices) { [weak self] event in self?.receive(event) }
        self.watcher = watcher
        do { try watcher.start() }
        catch { ready = false; devices = []; status = "USB observation failed. Restart to retry." }
    }

    private func endObservation() {
        selection?.invalidate()
        selectionMessage = "Observation ended. Select a device again when observation resumes."
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
        case let .removed(instance, _):
            if selection?.removed(instance) == true {
                selectionMessage = "The selected USB connection was removed. No lock was requested in this diagnostic view."
            }
            removedCount += 1; devices = watcher?.inventory ?? []
        case let .reconciled(inventory):
            devices = inventory
            if selection != nil, let watcher {
                do { try selection?.reconcile(inventory, watcherID: watcher.watcherID) }
                catch { selectionMessage = "Selection expired. Choose the current USB connection again." }
            }
        case .failed:
            selection?.invalidate()
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
                Text("Choose a USB connection").font(.largeTitle.weight(.semibold))
                Text("Choose the device whose removal will act as your switch. Selection currently tests detection; automatic protection is not yet available.")
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
                    ContentUnavailableView(inspector.ready ? "No USB device visible" : "No current device inventory",
                        systemImage: "cable.connector", description: Text("Connect your USB device and allow the accessory in macOS if prompted."))
                        .frame(maxWidth: .infinity, minHeight: 180)
                }
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(inspector.devices, id: \.instance) { device in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(device.displayName ?? "USB device").font(.headline)
                                Text(String(format: "USB %04X:%04X · Instance %@", device.vendorID, device.productID, inspector.token(for: device)))
                                    .font(.callout.monospaced()).foregroundStyle(.secondary)
                                Text(inspector.reason(for: device)).fixedSize(horizontal: false, vertical: true)
                                Button(inspector.selected(device) ? "Selected" : "Select this connection") { inspector.select(device) }
                                    .disabled(!inspector.ready || inspector.selected(device))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        }
                    }
                }
            }
            Text(inspector.selectionMessage).font(.callout).foregroundStyle(.secondary)
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
                Text("Device contents are never opened. Selection expires when this observation ends.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Open simulations") { openWindow(id: "simulation") }
                Button("Test screen lock…") { openWindow(id: "lock-test") }
            }
        }
        .padding(28)
        .onAppear { inspector.start() }
        .onDisappear { inspector.stop() }
    }
}
