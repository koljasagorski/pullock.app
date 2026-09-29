import AppKit

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var services: ServiceInspector?
    private var quitting = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let services, services.mayBeArmed else { return .terminateNow }
        guard !quitting else { return .terminateCancel }
        let alert = NSAlert()
        alert.messageText = "Disarm Pullock before quitting?"
        alert.informativeText = "Pullock must confirm that monitoring is disarmed before this app closes."
        alert.addButton(withTitle: "Disarm and Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        quitting = true
        Task {
            let allowed = await services.disarmBeforeQuit()
            quitting = false
            sender.reply(toApplicationShouldTerminate: allowed)
        }
        return .terminateLater
    }
}
