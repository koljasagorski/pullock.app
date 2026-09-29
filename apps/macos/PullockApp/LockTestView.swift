import AppKit
import PullockActions
import SwiftUI

struct LockTestView: View {
    @State private var permitted = false
    @State private var confirm = false
    @State private var message = "No lock requested."
    private let adapter = ShortcutLock()

    var body: some View {
        Form {
            Section {
                Text("Test screen lock").font(.title.bold())
                Text("This test sends macOS the Control–Command–Q shortcut. It interrupts your current session; unlock normally afterwards.")
            }
            Section("Input permission") {
                LabeledContent("macOS permission", value: permitted ? "Granted" : "Required")
                Button("Request input permission") {
                    ShortcutLock.requestPermission()
                    refresh()
                }
                Button("Check permission again", action: refresh)
                Text("Grant permission to Pullock Development in the macOS prompt or Accessibility settings. This does not read keyboard input or USB contents.")
                    .foregroundStyle(.secondary)
            }
            Section("Manual test") {
                Button("Lock this Mac now…") { confirm = true }.disabled(!permitted)
                Text(message)
                Text("“Lock requested” records only the shortcut submission. Check yourself that macOS actually locked. Test the session agent separately by choosing a USB device and explicitly arming Pullock.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
        .confirmationDialog("Lock this Mac now?", isPresented: $confirm) {
            Button("Send lock shortcut") { requestLock() }
        } message: {
            Text("macOS should show the lock screen immediately. Unlock with your usual password or Touch ID to return to this test.")
        }
    }

    private func refresh() { permitted = adapter.permissionGranted }
    private func requestLock() {
        do {
            try adapter.requestLock()
            message = "Lock requested. Actual lock success is not automatically confirmed."
        } catch let error as LockShortcutError {
            switch error {
            case .permissionRequired: message = "Permission is missing or was revoked. No shortcut sent."
            case .inactiveSession: message = "This is not the active console session. No shortcut sent."
            case .unsupportedKeyboardLayout: message = "The Q shortcut could not be resolved for this keyboard layout. No shortcut sent."
            case .eventCreationFailed: message = "macOS input events could not be created. No shortcut sent."
            }
        } catch { message = "Lock request failed." }
        refresh()
    }
}
