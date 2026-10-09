import SwiftUI

struct DatabaseServiceCard: View {
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
            }
        }
    }

    private var consumers: String {
        let names = infra.usedBy.compactMap { id in result.services.first { $0.id == id }?.name }
        return names.isEmpty ? "No services detected" : names.joined(separator: ", ")
    }
}
