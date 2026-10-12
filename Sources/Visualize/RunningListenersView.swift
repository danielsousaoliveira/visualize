import SwiftUI

struct RunningListenersView: View {
    @Environment(AppState.self) private var appState
    @State private var pendingStop: ProcessListener?
    @State private var busy: Set<String> = []
    let listeners: [ProcessListener]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Running instances").font(.callout.weight(.semibold))
            ForEach(listeners) { listener in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Label(listener.container == nil ? "Process · PID \(listener.pid)" : "Container · \(listener.container?.name ?? listener.name)", systemImage: "circle.fill")
                            .foregroundStyle(.green)
                        if let url = URL(string: "http://localhost:\(listener.port)") { Link(String(listener.port), destination: url) }
                        Spacer()
                        Button("Stop") {
                            if !listener.startedByVisualize && listener.container == nil { pendingStop = listener }
                            else { act(listener) }
                        }.help("Stop this instance")
                        Button("Restart") { act(listener, restart: true) }
                            .disabled(!appState.widgetRestartAvailable(listener))
                            .help(appState.widgetRestartAvailable(listener) ? "Restart this instance" : "Only instances started by visualize can be restarted")
                    }.disabled(busy.contains(listener.id))
                    if let branch = listener.gitBranch { Label(branch, systemImage: "arrow.triangle.branch") }
                    if let directory = listener.workingDirectory { Text(directory).textSelection(.enabled) }
                    Text(listener.startedByVisualize ? "Started by visualize" : "Started externally").foregroundStyle(.secondary)
                }.font(.callout)
            }
            if let error = appState.portLookupError ?? appState.listenerStore.actionError { Text(error).foregroundStyle(.red) }
        }
        .confirmationDialog("Stop external process?", isPresented: Binding(get: { pendingStop != nil }, set: { if !$0 { pendingStop = nil } }), presenting: pendingStop) { listener in
            Button("Stop \(listener.name)", role: .destructive) { act(listener, confirmed: true) }
            Button("Cancel", role: .cancel) {}
        } message: { listener in
            Text("Send SIGTERM to \(listener.name) (PID \(listener.pid)) listening on port \(listener.port)?")
        }
    }

    private func act(_ listener: ProcessListener, restart: Bool = false, confirmed: Bool = false) {
        guard busy.insert(listener.id).inserted else { return }
        Task {
            await appState.widgetAction(listener, restart: restart, externalStopConfirmed: confirmed)
            busy.remove(listener.id)
        }
    }
}
