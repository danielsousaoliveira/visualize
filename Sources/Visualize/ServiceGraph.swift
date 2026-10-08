import Foundation

struct ServiceGraph: Hashable {
    var nodes: [ServiceGraphNode]
    var edges: [ServiceGraphEdge]
    var warnings: [String] = []
    var layers: [[String]] = []
    var positions: [String: GraphPosition] = [:]

    init(scan: ScanResult, savedPositions: [String: GraphPosition] = [:]) {
        var aliases: [String: String] = [:]
        var canonical: [String: ServiceGraphNode] = [:]
        for service in scan.services where canonical[service.id] == nil {
            canonical[service.id] = ServiceGraphNode(id: service.id, name: service.name, kind: service.kind, infraKinds: [], category: service.category)
        }
        let entries = Dictionary(grouping: scan.infra.fillingMissingIds(), by: \.id)
        for id in entries.keys.sorted() {
            let group = entries[id]!
            let providers = group.compactMap(\.providedBy).filter { canonical[$0]?.kind == .compose }.sorted()
            let target = canonical[id] != nil ? id : (providers.first ?? id)
            aliases[id] = target
            if canonical[target] == nil {
                canonical[target] = ServiceGraphNode(id: target, name: group.map { $0.kind.rawValue }.sorted().first!, kind: nil, infraKinds: [])
            }
            canonical[target]!.infraKinds = Array(Set(canonical[target]!.infraKinds + group.map(\.kind))).sorted { $0.rawValue < $1.rawValue }
        }
        edges = scan.connections.enumerated().map { index, edge in
            ServiceGraphEdge(id: index, from: aliases[edge.from] ?? edge.from, to: aliases[edge.to] ?? edge.to, kind: edge.kind, label: edge.label)
        }
        for id in Set(edges.flatMap { [$0.from, $0.to] }).sorted() where canonical[id] == nil {
            canonical[id] = ServiceGraphNode(id: id, name: id, kind: nil, infraKinds: [])
            warnings.append("Connection endpoint \(id) was not present in the scan; represented as an unknown node.")
        }
        nodes = canonical.values.sorted { $0.id < $1.id }
        ServiceGraphLayout.apply(to: &self, savedPositions: savedPositions)
    }
}
