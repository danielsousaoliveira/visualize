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
        VisualizeScenes(appState: appState)
    }
}
