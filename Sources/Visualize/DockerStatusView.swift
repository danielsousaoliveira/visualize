import SwiftUI

struct DockerStatusView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(appState.dockerState.message).font(.callout)
            if case .running(_, false) = appState.dockerState {
                Text("Docker Compose v2 plugin is missing").font(.caption).foregroundStyle(.secondary)
            }
            Button("Check again") { Task { await appState.checkDocker() } }
                .disabled(appState.isCheckingDocker)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
