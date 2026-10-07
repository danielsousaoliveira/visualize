import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var appState: AppState?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let state = Self.appState, state.hasOwnedProcesses else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Services are still running"
        alert.informativeText = "Stop the services visualize started, or leave them running after quitting?"
        alert.addButton(withTitle: "Stop them")
        alert.addButton(withTitle: "Leave running")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task {
                await state.stopForQuit()
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        case .alertSecondButtonReturn: return .terminateNow
        default: return .terminateCancel
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
