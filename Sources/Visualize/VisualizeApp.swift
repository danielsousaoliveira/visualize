import SwiftUI

struct VisualizeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState: AppState

    init() {
        let appState = AppState()
        _appState = State(initialValue: appState)
        AppDelegate.appState = appState
        Task { await appState.scanProjectsWithoutResults() }
        Task { await appState.checkDocker() }
    }

    var body: some Scene {
        Window("visualize", id: MainWindow.id) {
            MainWindow()
                .environment(appState)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    Task { await appState.checkDocker() }
                }
        }
        .commands {
            LibraryCommands(appState: appState)
        }

        MenuBarExtra("visualize", systemImage: "circle.hexagongrid") {
            MenuBarPopover()
                .environment(appState)
        }
        .menuBarExtraStyle(.window)
    }
}
