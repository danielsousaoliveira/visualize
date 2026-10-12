import SwiftUI

struct InfraCard: View {
    let infra: ScanInfra
    let services: [ScanService]

    var body: some View {
        InsetSurface {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    TechnologyIcon(technology: infra.kind.rawValue)
                    Text(kindName).font(.headline)
                }
                Text("Used by: \(infra.usedBy.isEmpty ? "No services detected" : infra.usedBy.map(serviceName).joined(separator: ", "))")
                if infra.host != nil || infra.port != nil {
                    HStack(spacing: 20) {
                        if let host = infra.host { Text("Host: \(host)") }
                        if let port = infra.port { Text("Port: \(String(port))") }
                    }
                    .font(.callout.monospaced())
                }
                Text(infra.providedBy.map { "Provided by compose service: \(serviceName($0))" } ?? "No compose provider detected")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Evidence").font(.callout.weight(.medium))
                    ForEach(Array(infra.evidence.enumerated()), id: \.offset) { _, evidence in
                        Text(evidence).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)

        }
    }

    private var kindName: String {
        switch infra.kind {
        case .postgres: "Postgres"
        case .mysql: "MySQL"
        case .mongodb: "MongoDB"
        case .redis: "Redis"
        case .sqlite: "SQLite"
        }
    }

    private func serviceName(_ id: String) -> String {
        services.first { $0.id == id }?.name ?? id
    }
}
