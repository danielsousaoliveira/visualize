import Foundation

struct ProjectRunPlan {
    let dependencies: [String: Set<String>]
    let layers: [[[String]]]
    let cycles: [[String]]

    init(ids: [String], dependencies: [String: Set<String>]) {
        let known = Set(ids)
        self.dependencies = dependencies.mapValues { $0.intersection(known) }
        func reaches(_ from: String, _ target: String, visited: Set<String> = []) -> Bool {
            if from == target { return true }
            if visited.contains(from) { return false }
            return dependencies[from, default: []].contains { reaches($0, target, visited: visited.union([from])) }
        }
        var remaining = known
        var components: [[String]] = []
        for id in ids where remaining.contains(id) {
            let component = ids.filter { remaining.contains($0) && reaches(id, $0) && reaches($0, id) }
            components.append(component)
            remaining.subtract(component)
        }
        cycles = components.filter { $0.count > 1 || dependencies[$0[0], default: []].contains($0[0]) }
        var result: [[[String]]] = []
        while !components.isEmpty {
            let pending = Set(components.flatMap { $0 })
            let ready = components.filter { component in
                component.allSatisfy { dependencies[$0, default: []].intersection(pending).isSubset(of: Set(component)) }
            }
            result.append(ready)
            let removed = Set(ready.flatMap { $0 })
            components.removeAll { removed.contains($0[0]) }
        }
        layers = result
    }

    init(result: ScanResult) {
        let known = Set(result.services.map(\.id))
        var dependencies: [String: Set<String>] = [:]
        for edge in result.connections where edge.kind == .dependsOn || edge.kind == .usesInfra || edge.kind == .envURL {
            let target = known.contains(edge.to) ? edge.to : result.infra.first { $0.id == edge.to }?.providedBy
            if let target, known.contains(target) { dependencies[edge.from, default: []].insert(target) }
        }
        self.init(ids: result.services.map(\.id), dependencies: dependencies)
    }
}
