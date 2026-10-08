import Foundation

struct ServiceGraph: Hashable {
    var nodes: [ServiceGraphNode]
    var edges: [ServiceGraphEdge]
    var layers: [[String]] = []
    var positions: [String: GraphPosition] = [:]

    init(scan: ScanResult, savedPositions: [String: GraphPosition] = [:]) {
        var aliases: [String: String] = [:]
        var nodes = scan.services.map {
            ServiceGraphNode(id: $0.id, name: $0.name, kind: $0.kind, infraKinds: [])
        }
        for infra in scan.infra.fillingMissingIds() {
            if let provider = infra.providedBy,
               let index = nodes.firstIndex(where: { $0.id == provider && $0.kind == .compose }) {
                aliases[infra.id] = provider
                if !nodes[index].infraKinds.contains(infra.kind) { nodes[index].infraKinds.append(infra.kind) }
            } else {
                nodes.append(ServiceGraphNode(id: infra.id, name: infra.kind.rawValue, kind: nil, infraKinds: [infra.kind]))
            }
        }
        self.nodes = nodes.sorted { $0.id < $1.id }
        edges = scan.connections.enumerated().map { index, edge in
            ServiceGraphEdge(id: index, from: aliases[edge.from] ?? edge.from, to: aliases[edge.to] ?? edge.to, kind: edge.kind, label: edge.label)
        }
        ServiceGraphLayout.apply(to: &self, savedPositions: savedPositions)
    }
}
