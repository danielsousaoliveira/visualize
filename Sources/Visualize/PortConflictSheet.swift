import SwiftUI

struct PortConflictSheet: View {
    @Environment(AppState.self) private var appState
    let conflict: PortConflict
    @State private var confirmingTermination = false

    private var canStop: Bool { conflict.owners.allSatisfy(\.canStop) }
    private var needsConfirmation: Bool {
        conflict.owners.contains { $0.containerID == nil && !appState.owns($0) }
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
                    if !owner.canStop {
                        Text("Owned by another user").foregroundStyle(.secondary)
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
                    if needsConfirmation { confirmingTermination = true }
                    else { Task { await appState.resolve(conflict, stopOwners: true) } }
                }
                .disabled(!canStop)
                .help(canStop ? "Stop the port owner and start this service" : "Owned by another user")
            }
        }
        .padding(24)
        .frame(minWidth: 560)
        .confirmationDialog("Stop this external process?", isPresented: $confirmingTermination, titleVisibility: .visible) {
            Button("Send SIGTERM and start", role: .destructive) {
                Task { await appState.resolve(conflict, stopOwners: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("These processes were not started by visualize. Sending SIGTERM asks them to exit and may interrupt their work.")
        }
    }
}
