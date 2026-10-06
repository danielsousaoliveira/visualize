import SwiftUI

@main
struct VisualizeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState()

    var body: some Scene {
        Window("visualize", id: MainWindow.id) {
            MainWindow()
                .environment(appState)
        }
        .commands {
            ScanCommands(appState: appState)
        }

        MenuBarExtra("visualize", systemImage: "circle.hexagongrid") {
            MenuBarPopover()
                .environment(appState)
        }
        .menuBarExtraStyle(.window)
    }
}
