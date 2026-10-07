import SwiftUI

struct PortConflictSheet: View {
    @Environment(AppState.self) private var appState
    let conflict: PortConflict
    private var canStop: Bool { conflict.owners.allSatisfy { appState.owns($0) } }
    private var stopUnavailableReason: String {
        conflict.owners.compactMap { appState.stopUnavailableReason(for: $0) }.first ?? "Stop the port owner and start this service"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Port already in use").font(.title2)
            ForEach(conflict.owners) { owner in
                VStack(alignment: .leading, spacing: 4) {
                    Text(owner.title).font(.headline).textSelection(.enabled)
                    if let compose = owner.composeProject {
                        Text("Compose project: \(compose)")
                    } else if let project = appState.projectName(for: owner) {
                        Text("Project: \(project)")
                    }
                    if let reason = appState.stopUnavailableReason(for: owner) {
                        Text(reason).foregroundStyle(.secondary)
                    }
                }
            }
            Text("Start anyway allows frameworks to choose their next free port.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { appState.portConflict = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Start anyway") { Task { await appState.resolve(conflict, stopOwners: false) } }
                Button("Stop it and start") {
                    Task { await appState.resolve(conflict, stopOwners: true) }
                }
                .disabled(!canStop)
                .help(stopUnavailableReason)
            }
        }
        .padding(24)
        .frame(minWidth: 560)
    }
}
