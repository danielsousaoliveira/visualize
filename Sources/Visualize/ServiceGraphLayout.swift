import Foundation

struct ServiceGraphLayout {
    static let exactCycleLimit = 10

    static func apply(to graph: inout ServiceGraph, savedPositions: [String: GraphPosition] = [:], reduceCrossings: Bool = true) {
        let ids = graph.nodes.map(\.id)
        let priorities = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0.layoutPriority) })
        let knownEdges = graph.edges.filter { priorities[$0.from] != nil && priorities[$0.to] != nil }
        let realComponents = components(ids, edges: knownEdges.map { ($0.from, $0.to) })
        let realSizes = Dictionary(grouping: ids, by: { realComponents[$0]! }).mapValues(\.count)
        var normalized = knownEdges.map { edge -> ServiceGraphEdge in
            var result = edge
            result.from = edge.consumerID
            result.to = edge.dependencyID
            if priorities[result.from]! < priorities[result.to]! { swap(&result.from, &result.to) }
            return result
        }
        let layoutComponents = components(ids, edges: normalized.map { ($0.from, $0.to) })
        let groups = Dictionary(grouping: ids, by: { layoutComponents[$0]! })
        var rank: [String: Int] = [:]
        let groupedEdges = Dictionary(grouping: normalized.filter { layoutComponents[$0.from] == layoutComponents[$0.to] && $0.from != $0.to }, by: { layoutComponents[$0.from]! })
        for key in groups.keys.sorted() {
            let order = reversalOrder(groups[key]!.sorted(), edges: groupedEdges[key] ?? [])
            for (index, id) in order.enumerated() { rank[id] = index }
        }
        for index in normalized.indices {
            if normalized[index].from != normalized[index].to,
               layoutComponents[normalized[index].from] == layoutComponents[normalized[index].to],
               rank[normalized[index].from]! < rank[normalized[index].to]! {
                let from = normalized[index].from
                normalized[index].from = normalized[index].to
                normalized[index].to = from
            }
        }
        let byID = Dictionary(uniqueKeysWithValues: normalized.map { ($0.id, $0) })
        for index in graph.edges.indices {
            let edge = graph.edges[index]
            graph.edges[index].isCyclic = realComponents[edge.from] != nil && realComponents[edge.from] == realComponents[edge.to]
                && (edge.from == edge.to || (realComponents[edge.from].flatMap { realSizes[$0] } ?? 0) > 1)
            graph.edges[index].reversedForLayout = byID[edge.id].map { $0.from != edge.from } ?? false
        }
        let dependencies = normalized.filter { $0.from != $0.to && priorities[$0.from] != 0 }.map { ($0.from, $0.to) }
        var consumers: [String: [String]] = [:]
        var outstanding: [String: Int] = [:]
        let hasInfra = priorities.values.contains(0)
        var layer = Dictionary(uniqueKeysWithValues: ids.map { ($0, priorities[$0] == 0 ? 0 : (hasInfra ? 1 : 0)) })
        for (from, to) in dependencies {
            consumers[to, default: []].append(from)
            outstanding[from, default: 0] += 1
        }
        var queue = ids.filter { outstanding[$0, default: 0] == 0 }
        var cursor = 0
        while cursor < queue.count {
            let id = queue[cursor]
            cursor += 1
            for consumer in consumers[id, default: []] {
                layer[consumer] = max(layer[consumer]!, layer[id]! + 1)
                outstanding[consumer]! -= 1
                if outstanding[consumer] == 0 { queue.append(consumer) }
            }
        }
        let backendMax = ids.filter { priorities[$0] == 1 }.compactMap { layer[$0] }.max()
        if let backendMax {
            let frontends = ids.filter { priorities[$0] == 2 }
            if let minimum = frontends.compactMap({ layer[$0] }).min(), minimum <= backendMax {
                for id in frontends { layer[id]! += backendMax + 1 - minimum }
            }
        }
        graph.layers = Array(repeating: [], count: layer.values.max().map { $0 + 1 } ?? 0)
        for id in ids { graph.layers[layer[id]!].append(id) }
        if reduceCrossings { barycentre(&graph.layers, dependencies: dependencies) }
        graph.positions = [:]
        for (x, row) in graph.layers.enumerated() {
            for (y, id) in row.enumerated() {
                graph.positions[id] = savedPositions[id] ?? GraphPosition(x: Double(x) * 320, y: Double(y) * 160)
            }
        }
    }

    private static func components(_ ids: [String], edges: [(String, String)]) -> [String: Int] {
        var outgoing: [String: [String]] = [:]
        var incoming: [String: [String]] = [:]
        for (from, to) in edges {
            outgoing[from, default: []].append(to)
            incoming[to, default: []].append(from)
        }
        var seen: Set<String> = []
        var finished: [String] = []
        for id in ids where !seen.contains(id) {
            var stack: [(String, Bool)] = [(id, false)]
            while let (node, exit) = stack.popLast() {
                if exit { finished.append(node); continue }
                guard seen.insert(node).inserted else { continue }
                stack.append((node, true))
                for next in outgoing[node, default: []].reversed() where !seen.contains(next) { stack.append((next, false)) }
            }
        }
        var result: [String: Int] = [:]
        var component = 0
        for id in finished.reversed() where result[id] == nil {
            var stack = [id]
            result[id] = component
            while let node = stack.popLast() {
                for next in incoming[node, default: []] where result[next] == nil {
                    result[next] = component
                    stack.append(next)
                }
            }
            component += 1
        }
        return result
    }

    private static func reversalOrder(_ ids: [String], edges: [ServiceGraphEdge]) -> [String] {
        guard ids.count > 1 else { return ids }
        var outgoing: [String: [String]] = [:]
        var incoming: [String: [String]] = [:]
        for edge in edges {
            outgoing[edge.from, default: []].append(edge.to)
            incoming[edge.to, default: []].append(edge.from)
        }
        var remaining = Set(ids)
        var scores = Dictionary(uniqueKeysWithValues: ids.map { ($0, outgoing[$0, default: []].count - incoming[$0, default: []].count) })
        var heuristic: [String] = []
        while !remaining.isEmpty {
            let next = ids.filter { remaining.contains($0) }.min { a, b in
                scores[a] == scores[b] ? a < b : scores[a]! < scores[b]!
            }!
            heuristic.append(next)
            remaining.remove(next)
            for source in incoming[next, default: []] where remaining.contains(source) { scores[source]! -= 1 }
            for target in outgoing[next, default: []] where remaining.contains(target) { scores[target]! += 1 }
        }
        guard ids.count <= exactCycleLimit else { return heuristic }
        var best = heuristic
        let ranks = Dictionary(uniqueKeysWithValues: best.enumerated().map { ($0.element, $0.offset) })
        var bestCost = edges.filter { ranks[$0.from]! < ranks[$0.to]! }.count
        var memo: [Set<String>: Int] = [:]
        func search(_ prefix: [String], _ remaining: Set<String>, _ score: Int) {
            guard score < bestCost else { return }
            if remaining.isEmpty { best = prefix; bestCost = score; return }
            if let previous = memo[remaining], previous <= score { return }
            memo[remaining] = score
            for id in ids where remaining.contains(id) {
                let rest = remaining.subtracting([id])
                let added = outgoing[id, default: []].filter { rest.contains($0) }.count
                search(prefix + [id], rest, score + added)
            }
        }
        search([], Set(ids), 0)
        return best
    }

    private static func barycentre(_ layers: inout [[String]], dependencies: [(String, String)]) {
        guard layers.count > 1 else { return }
        var neighbours: [String: [String]] = [:]
        for (from, to) in dependencies {
            neighbours[from, default: []].append(to)
            neighbours[to, default: []].append(from)
        }
        var best = layers
        var bestCount = crossings(layers, dependencies: dependencies)
        for _ in 0..<8 {
            for forward in [true, false] {
                let indices = forward ? Array(1..<layers.count) : Array((0..<(layers.count - 1)).reversed())
                for index in indices {
                    let adjacent = index + (forward ? -1 : 1)
                    let ranks = Dictionary(uniqueKeysWithValues: layers[adjacent].enumerated().map { ($0.element, Double($0.offset)) })
                    let original = Dictionary(uniqueKeysWithValues: layers[index].enumerated().map { ($0.element, $0.offset) })
                    let centres = Dictionary(uniqueKeysWithValues: layers[index].map { id in
                        let values = neighbours[id, default: []].compactMap { ranks[$0] }
                        return (id, values.isEmpty ? Double(original[id]!) : values.reduce(0, +) / Double(values.count))
                    })
                    layers[index].sort { centres[$0] == centres[$1] ? original[$0]! < original[$1]! : centres[$0]! < centres[$1]! }
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
        var pairs: [Int: [(Int, Int)]] = [:]
        for (from, to) in dependencies {
            guard let a = positions[from], let b = positions[to], abs(a.0 - b.0) == 1 else { continue }
            let left = a.0 < b.0 ? a : b
            let right = a.0 < b.0 ? b : a
            pairs[left.0, default: []].append((left.1, right.1))
        }
        var count = 0
        for (index, edges) in pairs {
            let sorted = edges.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
            var tree = Array(repeating: 0, count: layers[index + 1].count + 1)
            var processed = 0
            for (_, right) in sorted {
                var cursor = right + 1
                var lowerOrEqual = 0
                while cursor > 0 { lowerOrEqual += tree[cursor]; cursor -= cursor & -cursor }
                count += processed - lowerOrEqual
                cursor = right + 1
                while cursor < tree.count { tree[cursor] += 1; cursor += cursor & -cursor }
                processed += 1
            }
        }
        return count
    }
}
