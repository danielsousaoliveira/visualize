import SwiftUI

struct DatabaseServiceCard: View {
    @Environment(AppState.self) private var appState
    let project: Project
    let infra: ScanInfra
    let result: ScanResult

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let provider = result.services.first(where: { $0.id == infra.providedBy }) {
                ServiceCard(project: project, service: provider, environment: result.envRequirements.first { $0.serviceId == provider.id })
                Text("\(infra.kind.rawValue) • Used by: \(consumers)")
                    .font(.callout).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else {
                InfraCard(infra: infra, services: result.services)
                let listeners = appState.listenerStore.listeners.filter {
                    $0.libraryProjectID == project.id && $0.serviceID == nil && $0.port == infra.port
                }
                if !listeners.isEmpty { RunningListenersView(listeners: listeners) }
            }
        }
    }

    private var consumers: String {
        let names = infra.usedBy.compactMap { id in result.services.first { $0.id == id }?.name }
        return names.isEmpty ? "No services detected" : names.joined(separator: ", ")
    }
}
