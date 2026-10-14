import SwiftUI

struct GraphNodeCard: View {
    @Environment(AppState.self) private var appState
    let project: Project
    let node: ServiceGraphNode
    let selected: Bool
    static let size = CGSize(width: 260, height: 116)

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
        if let service { return service.port }
        return project.lastResult?.infra.fillingMissingIds().first { $0.id == node.id || $0.providedBy == node.id }?.port
    }

    private var technology: String? {
        if let stack = service?.stackId { return stack }
        if let kind = node.infraKinds.first { return kind.rawValue }
        return project.lastResult?.composeServices.first {
            $0.name == service?.runModes.compose.serviceName && $0.composeFile == service?.runModes.compose.composeFile
        }?.image?.components(separatedBy: ":").first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TechnologyIcon(technology: technology, size: 16)
                Text(node.name).font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 2)
                Circle().fill(status).frame(width: 9, height: 9)
                    .accessibilityLabel(run?.status ?? "Stopped")
            }
            if let file = service?.runModes.compose.composeFile {
                Text(file).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            HStack {
                Text(service?.stackId ?? node.infraKinds.map(\.rawValue).joined(separator: ", "))
                    .lineLimit(1)
                Spacer(minLength: 2)
                if let port { Text(":" + String(port)).monospaced() }
            }.font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(run?.status ?? (service == nil ? (node.infraKinds.contains(.sqlite) ? "Embedded" : "Dependency") : node.category == "mobile" ? "Open in IDE" : "Stopped")).font(.caption).lineLimit(1)
                Spacer()
                if let service, !ServiceMode.available(for: service).isEmpty {
                    if run?.active == true {
                        Button {
                            Task { await appState.stop(project: project, service: service) }
                        } label: { Image(systemName: "stop.fill") }.help("Stop \(node.name)")
                        .accessibilityLabel("Stop \(node.name)")
                        .disabled(run?.busy == true || run?.stopping == true || (run?.pid == nil && run?.docker == nil) || appState.projectOperations[project.id]?.busy == true)
                    } else {
                        ServicePlayButton(project: project, service: service, iconOnly: true)
                    }
                }
            }
        }
        .padding(12).frame(width: Self.size.width, height: Self.size.height)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.primary.opacity(0.7) : Color.secondary.opacity(0.2), lineWidth: selected ? 2 : 1))
    }
}
