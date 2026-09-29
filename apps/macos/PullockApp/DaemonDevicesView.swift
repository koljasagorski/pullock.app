import PullockServices
import SwiftUI

/// The background service owns this inventory and selection. Closing the
/// window leaves the app's authenticated client and the daemon running.
struct DaemonDevicesView: View {
    @Environment(ServiceInspector.self) private var inspector
    @Environment(\.openWindow) private var openWindow
    @State private var confirmArm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("DEVELOPMENT · AUTOMATIC LOCK TEST").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Image("PullockSymbol").resizable().scaledToFit().frame(width: 64, height: 64)
                    .accessibilityLabel("Pullock")
                Text("Pull the key. Lock the Device.").font(.largeTitle.weight(.semibold))
            }
            Text("Choose any detected compatible USB device, then arm Pullock. Disconnecting that selected device requests a Mac screen lock.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Connect to background service") { inspector.connect() }
                Button("Set up services…") { openWindow(id: "services") }
                Button("Local USB inspection…") { openWindow(id: "local-usb") }
                Spacer()
            }
            Text(inspector.connection).font(.callout)
            Divider()
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let fresh = inspector.snapshot.map {
                    $0.generatedAt <= MonotonicTime.milliseconds && MonotonicTime.milliseconds < $0.validUntil
                } ?? false
                if !fresh {
                    ContentUnavailableView("Background service unavailable", systemImage: "cable.connector.slash",
                        description: Text("Set up and approve the background services, then connect to choose a device. Local USB inspection is also available."))
                } else if inspector.devices.isEmpty {
                    ContentUnavailableView("No USB devices found", systemImage: "cable.connector",
                        description: Text("Connect a USB device and approve it in macOS if prompted."))
                } else {
                    List(inspector.devices, id: \.instance) { device in
                        HStack(spacing: 14) {
                            Image(systemName: "cable.connector").font(.title2)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(device.name ?? "USB device").font(.headline)
                                Text(String(format: "%04X:%04X · Connection %llu", device.vendorID, device.productID, device.instance))
                                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if inspector.selectedInstance == device.instance {
                                Label("Selected", systemImage: "checkmark.circle")
                            } else {
                                Button("Choose") { inspector.choose(device) }.disabled(!inspector.canChoose)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                VStack(alignment: .leading, spacing: 10) {
                    Text(inspector.protectionLabel).font(.headline).accessibilityAddTraits(.updatesFrequently)
                    HStack {
                        Button("Arm Pullock…") { confirmArm = true }.disabled(!inspector.canArm)
                            .buttonStyle(.borderedProminent)
                        Button("Disarm") { inspector.disarm() }
                            .disabled(inspector.busy || inspector.freshSnapshot?.armIntent != true || inspector.freshSnapshot?.trigger != nil)
                        if inspector.freshSnapshot?.trigger != nil {
                            Button("Reset after trigger") { inspector.resetTrigger() }
                                .disabled(inspector.busy || inspector.freshSnapshot?.lockOutcome?.isTerminal != true)
                        }
                    }
                    if !inspector.lockRouteReady {
                        Text("Set up the session agent and its screen lock permission before arming.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            Text(inspector.selectionMessage).font(.callout)
            Text("USB sticks and other observable USB devices are supported for selection. Contents are never opened. Unplugging, sleep, a session change or a service restart requires a new selection.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Test build: shortcut submission does not confirm that macOS locked. Verify the lock screen and normal authentication during your test.")
                .font(.caption).foregroundStyle(.secondary)
            if let message = inspector.message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(28)
        .confirmationDialog("Arm this USB connection?", isPresented: $confirmArm) {
            Button("Arm and enable real lock requests") { inspector.arm() }
        } message: {
            Text("Disconnecting the selected device will request Control–Command–Q. A failure of the monitoring connection can also request a lock. Unlock normally afterwards; disarm before quitting or removing services.")
        }
    }
}
