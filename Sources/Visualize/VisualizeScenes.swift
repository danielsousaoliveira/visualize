import SwiftUI

struct VisualizeScenes: Scene {
    let appState: AppState

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

        Settings {
            AppSettingsView().environment(appState)
        }

        MenuBarExtra {
            MenuBarPopover()
                .environment(appState)
        }
        label: {
            MenuBarLabel(listenerStore: appState.listenerStore)
        }
        .menuBarExtraStyle(.window)
    }
}
