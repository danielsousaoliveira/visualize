import SwiftUI

struct DockerStatusView: View {
    @Environment(AppState.self) private var appState

    private var available: Bool { appState.dockerState.unavailableReason() == nil }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: available ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(available ? Color.green : Color.secondary)
            Text(appState.dockerState.message)
            if case .running(_, false) = appState.dockerState {
                Text("Compose v2 unavailable").foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .combine)
    }
}
