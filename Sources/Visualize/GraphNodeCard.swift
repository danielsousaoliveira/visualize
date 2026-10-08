import SwiftUI

struct GraphNodeCard: View {
    @Environment(AppState.self) private var appState
    let project: Project
    let node: ServiceGraphNode
    let selected: Bool
    static let size = CGSize(width: 216, height: 96)

    private var service: ScanService? { project.lastResult?.services.first { $0.id == node.id } }
    private var run: ServiceRun? { service.flatMap { appState.serviceRuns[appState.runKey(project: project, service: $0)] } }
    private var status: Color {
        guard let run else { return .gray }
        if run.status.lowercased().contains("failed") { return .red }
        if !run.active { return ["Exited", "Exited (0)", "Stopped"].contains(run.status) ? .gray : .red }
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
                    if run?.active == true {
                        Button {
                            Task { await appState.stop(project: project, service: service) }
                        } label: { Image(systemName: "stop.fill") }
                        .accessibilityLabel("Stop \(node.name)")
                        .disabled(run?.busy == true || run?.stopping == true || (run?.pid == nil && run?.docker == nil) || appState.projectOperations[project.id]?.busy == true)
                    } else {
                        ServicePlayButton(project: project, service: service, iconOnly: true)
                    }
                }
            }
        }
        .padding(12).frame(width: Self.size.width, height: Self.size.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: selected ? 2 : 1))
    }
}
