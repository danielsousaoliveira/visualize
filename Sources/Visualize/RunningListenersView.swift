import SwiftUI

struct RunningListenersView: View {
    @Environment(AppState.self) private var appState
    @State private var pendingStop: ProcessListener?
    @State private var busy: Set<String> = []
    @State private var expanded: Set<String> = []
    let listeners: [ProcessListener]
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(listeners) { listener in
                InsetSurface(inset: !compact) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Circle().fill(.green).frame(width: 6, height: 6)
                        Text(listener.serviceName ?? listener.container?.name ?? listener.name).fontWeight(.medium).lineLimit(1).truncationMode(.middle).layoutPriority(1)
                        if let url = URL(string: "http://localhost:\(listener.port)") { Link("localhost:\(listener.port)", destination: url).foregroundStyle(.primary).monospacedDigit() }
                        Spacer()
                        Button("Stop") {
                            if !listener.startedByVisualize && listener.container == nil { pendingStop = listener }
                            else { act(listener) }
                        }.help("Stop this instance")
                        Button("Restart") { act(listener, restart: true) }
                            .disabled(!appState.widgetRestartAvailable(listener))
                            .help(appState.widgetRestartAvailable(listener) ? "Restart this instance" : "Only instances started by visualize can be restarted")
                    }.disabled(busy.contains(listener.id))
                    DisclosureGroup(isExpanded: Binding(get: { expanded.contains(listener.id) }, set: { if $0 { expanded.insert(listener.id) } else { expanded.remove(listener.id) } })) {
                    Text("PID \(listener.pid)").monospacedDigit().foregroundStyle(.secondary)
                    if let branch = listener.gitBranch { Label(branch, systemImage: "arrow.triangle.branch") }
                    if let directory = listener.workingDirectory { Text(directory).textSelection(.enabled) }
                    } label: {
                        Text(listener.startedByVisualize ? "Started by visualize" : "Started externally").foregroundStyle(.secondary)
                    }.tint(.primary)
                }.font(.callout).controlSize(.small)
                }
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
