import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var appState: AppState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        sender.activate(ignoringOtherApps: true)
        return true
    }

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
                let stopped = await state.stopForQuit()
                sender.reply(toApplicationShouldTerminate: stopped)
                if !stopped {
                    let failure = NSAlert()
                    failure.messageText = "Some services could not be stopped"
                    failure.informativeText = "Check the service cards for details, then try quitting again."
                    failure.runModal()
                }
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
