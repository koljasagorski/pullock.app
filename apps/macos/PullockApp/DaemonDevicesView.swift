import PullockServices
import SwiftUI

/// The background service owns this inventory and selection. Closing the
/// window leaves the app's authenticated client and the daemon running.
struct DaemonDevicesView: View {
    @Environment(ServiceInspector.self) private var inspector
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("DEVELOPMENT · NO PROTECTION").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text("Choose your USB switch").font(.largeTitle.weight(.semibold))
            Text("Select the connection whose removal should request a screen lock. Automatic protection is still under development.")
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
                                Button("Choose") { inspector.choose(device) }.disabled(inspector.busy)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
            Text(inspector.selectionMessage).font(.callout)
            Text("Unplugging, sleep, a session change or a service restart requires a new selection. Device contents are never opened.")
                .font(.caption).foregroundStyle(.secondary)
            if let message = inspector.message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(28)
    }
}
