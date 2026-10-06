import SwiftUI

@main
struct VisualizeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState: AppState

    init() {
        let appState = AppState()
        _appState = State(initialValue: appState)
        Task { await appState.scanProjectsWithoutResults() }
    }

    var body: some Scene {
        Window("visualize", id: MainWindow.id) {
            MainWindow()
                .environment(appState)
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
