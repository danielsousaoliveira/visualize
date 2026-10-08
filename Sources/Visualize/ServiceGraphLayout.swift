import Foundation

struct ServiceGraphLayout {
    static func apply(to graph: inout ServiceGraph, savedPositions: [String: GraphPosition] = [:], reduceCrossings: Bool = true) {
        let ids = graph.nodes.map(\.id)
        let known = Set(ids)
        let edges = graph.edges.filter { known.contains($0.from) && known.contains($0.to) }
        var reach: [String: Set<String>] = [:]
        for id in ids {
            var pending = [id]
            var visited: Set<String> = []
            while let next = pending.popLast() {
                for edge in edges where edge.from == next {
                    if visited.insert(edge.to).inserted { pending.append(edge.to) }
                }
            }
            reach[id] = visited
        }
        var remaining = Set(ids)
        var rank: [String: Int] = [:]
        while let first = ids.first(where: { remaining.contains($0) }) {
            let component = ids.filter { $0 == first || (reach[first, default: []].contains($0) && reach[$0, default: []].contains(first)) }
            remaining.subtract(component)
            let internalEdges = edges.filter { component.contains($0.from) && component.contains($0.to) && $0.from != $0.to }
            let order = minimumReversalOrder(component, edges: internalEdges)
            for (index, id) in order.enumerated() { rank[id] = index }
        }
        for index in graph.edges.indices {
            let edge = graph.edges[index]
            let cyclic = known.contains(edge.from) && known.contains(edge.to) && (edge.from == edge.to || (reach[edge.from, default: []].contains(edge.to) && reach[edge.to, default: []].contains(edge.from)))
            graph.edges[index].isCyclic = cyclic
            graph.edges[index].reversedForLayout = cyclic && edge.from != edge.to && rank[edge.from, default: 0] < rank[edge.to, default: 0]
        }
        let dependencies = graph.edges.compactMap { edge -> (String, String)? in
            guard known.contains(edge.from), known.contains(edge.to), edge.from != edge.to else { return nil }
            return edge.reversedForLayout ? (edge.to, edge.from) : (edge.from, edge.to)
        }
        var layer: [String: Int] = [:]
        func assign(_ id: String) -> Int {
            if let value = layer[id] { return value }
            let value = dependencies.filter { $0.0 == id }.map { assign($0.1) + 1 }.max() ?? 0
            layer[id] = value
            return value
        }
        for id in ids { _ = assign(id) }
        graph.layers = (0..<(layer.values.max().map { $0 + 1 } ?? 0)).map { level in ids.filter { layer[$0] == level } }
        if reduceCrossings { barycentre(&graph.layers, dependencies: dependencies) }
        graph.positions = [:]
        for (x, row) in graph.layers.enumerated() {
            for (y, id) in row.enumerated() {
                graph.positions[id] = savedPositions[id] ?? GraphPosition(x: Double(x) * 320, y: Double(y) * 160)
            }
        }
    }

    private static func minimumReversalOrder(_ ids: [String], edges: [ServiceGraphEdge]) -> [String] {
        var best = ids
        func cost(_ order: [String]) -> Int {
            let ranks = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
            return edges.filter { ranks[$0.from]! < ranks[$0.to]! }.count
        }
        var bestCost = cost(best)
        var memo: [Set<String>: Int] = [:]
        func search(_ prefix: [String], _ remaining: Set<String>, _ score: Int) {
            guard score < bestCost else { return }
            if remaining.isEmpty { best = prefix; bestCost = score; return }
            if let previous = memo[remaining], previous <= score { return }
            memo[remaining] = score
            for id in ids where remaining.contains(id) {
                let rest = remaining.subtracting([id])
                let added = edges.filter { $0.from == id && rest.contains($0.to) }.count
                search(prefix + [id], rest, score + added)
            }
        }
        search([], Set(ids), 0)
        return best
    }

    private static func barycentre(_ layers: inout [[String]], dependencies: [(String, String)]) {
        guard layers.count > 1 else { return }
        var best = layers
        var bestCount = crossings(layers, dependencies: dependencies)
        for _ in 0..<8 {
            for forward in [true, false] {
                let indices = forward ? Array(1..<layers.count) : Array((0..<(layers.count - 1)).reversed())
                for index in indices {
                    let adjacent = index + (forward ? -1 : 1)
                    let ranks = Dictionary(uniqueKeysWithValues: layers[adjacent].enumerated().map { ($0.element, Double($0.offset)) })
                    let original = Dictionary(uniqueKeysWithValues: layers[index].enumerated().map { ($0.element, Double($0.offset)) })
                    func centre(_ id: String) -> Double {
                        let values = dependencies.compactMap { from, to in from == id ? ranks[to] : (to == id ? ranks[from] : nil) }
                        return values.isEmpty ? original[id]! : values.reduce(0, +) / Double(values.count)
                    }
                    layers[index].sort { centre($0) == centre($1) ? original[$0]! < original[$1]! : centre($0) < centre($1) }
                }
                let count = crossings(layers, dependencies: dependencies)
                if count < bestCount { best = layers; bestCount = count }
            }
        }
        layers = best
    }

    static func crossings(_ layers: [[String]], dependencies: [(String, String)]) -> Int {
        var positions: [String: (Int, Int)] = [:]
        for (layer, row) in layers.enumerated() {
            for (index, id) in row.enumerated() { positions[id] = (layer, index) }
        }
        var count = 0
        for (index, edge) in dependencies.enumerated() {
            guard let a = positions[edge.0], let b = positions[edge.1] else { continue }
            for other in dependencies.dropFirst(index + 1) {
                guard let c = positions[other.0], let d = positions[other.1], a.0 == c.0, b.0 == d.0 else { continue }
                if (a.1 - c.1) * (b.1 - d.1) < 0 { count += 1 }
            }
        }
        return count
    }
}
