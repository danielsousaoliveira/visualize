import SwiftUI

struct MainWindow: View {
    static let id = "main"

    @Environment(AppState.self) private var appState
    @State private var selection: Project.ID?

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            ScanStatusView(status: appState.scanStatus)
        }
        .frame(minWidth: 720, minHeight: 440)
    }

    @ViewBuilder
    private var sidebar: some View {
        if appState.projects.isEmpty {
            ContentUnavailableView("No projects yet", systemImage: "folder")
        } else {
            List(appState.projects, selection: $selection) { project in
                Text(project.name)
            }
        }
    }
}
