import SwiftUI

struct GraphNodeCard: View {
    @Environment(AppState.self) private var appState
    let project: Project
    let node: ServiceGraphNode
    let selected: Bool
    @State private var pendingRecipe: RunRecipe?
    @State private var confirming = false

    private var service: ScanService? { project.lastResult?.services.first { $0.id == node.id } }
    private var run: ServiceRun? { service.flatMap { appState.serviceRuns[appState.runKey(project: project, service: $0)] } }
    private var status: Color {
        guard let run else { return .gray }
        if run.status.lowercased().contains("failed") { return .red }
        if !run.active { return run.status == "Exited" || run.status == "Stopped" ? .gray : .red }
        if run.busy || run.stopping || (run.status.hasPrefix("Starting") || (service?.port != nil && !run.portReady)) { return .orange }
        return .green
    }
    private var port: Int? {
        service?.port ?? project.lastResult?.infra.fillingMissingIds().first { $0.id == node.id || $0.providedBy == node.id }?.port
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: node.infraKinds.isEmpty ? "shippingbox" : "externaldrive")
                Text(node.name).font(.headline).lineLimit(1)
                Spacer(minLength: 2)
                Circle().fill(status).frame(width: 9, height: 9)
                    .accessibilityLabel(run?.status ?? "Stopped")
            }
            HStack {
                Text(service?.stackId ?? node.infraKinds.map(\.rawValue).joined(separator: ", "))
                    .lineLimit(1)
                Spacer(minLength: 2)
                Text(port.map { ":\($0)" } ?? "—").monospaced()
            }.font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(run?.status ?? "Stopped").font(.caption).lineLimit(1)
                Spacer()
                if let service, !ServiceMode.available(for: service).isEmpty {
                    Button {
                        if run?.active == true {
                            Task { await appState.stop(project: project, service: service) }
                        } else if appState.mode(project: project, service: service) != .local {
                            Task { await appState.startDocker(project: project, service: service) }
                        } else if let recipe = appState.recipe(project: project, service: service) {
                            if appState.approved(recipe, project: project) {
                                Task { await appState.start(project: project, service: service, recipe: recipe) }
                            } else { pendingRecipe = recipe; confirming = true }
                        }
                    } label: {
                        Image(systemName: run?.active == true ? "stop.fill" : "play.fill")
                    }
                    .accessibilityLabel("\(run?.active == true ? "Stop" : "Play") \(node.name)")
                    .help(appState.dockerReason(project: project, service: service) ?? appState.mode(project: project, service: service).rawValue)
                    .disabled(run?.busy == true || run?.stopping == true || (run?.active == true && run?.pid == nil && run?.docker == nil) || (run?.active != true && appState.dockerReason(project: project, service: service) != nil) || appState.projectOperations[project.id]?.busy == true)
                }
            }
        }
        .padding(12).frame(width: 216, height: 96)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: selected ? 2 : 1))
        .sheet(isPresented: $confirming) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Run this command?").font(.title2)
                Text(pendingRecipe?.displayCommand ?? "").font(.body.monospaced()).textSelection(.enabled)
                Text(pendingRecipe?.workingDirectory ?? "").font(.callout.monospaced()).textSelection(.enabled)
                HStack {
                    Spacer()
                    Button("Cancel") { confirming = false }.keyboardShortcut(.cancelAction)
                    Button("Run") {
                        if let service, let recipe = pendingRecipe {
                            Task { await appState.start(project: project, service: service, recipe: recipe) }
                        }
                        confirming = false
                    }.keyboardShortcut(.defaultAction)
                }
            }.padding(24).frame(minWidth: 480)
        }
    }
}
