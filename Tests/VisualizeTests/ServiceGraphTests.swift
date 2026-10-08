import Foundation
import Testing
@testable import visualize

struct ServiceGraphTests {
    private func scan(_ ids: [String], edges: [ScanConnection], infra: [ScanInfra] = []) throws -> ScanResult {
        let services = ids.map { ["id": $0, "name": $0, "kind": $0.hasPrefix("compose:") ? "compose" : "app", "rootDirectory": ".", "hasDockerfile": false] as [String: Any] }
        let data = try JSONSerialization.data(withJSONObject: services)
        let decoded = try JSONDecoder().decode([ScanService].self, from: data)
        let golden = ScanDecoderTests.goldenDirectory.appending(path: "scan-compose-env.json")
        var scan = try ScanDecoder.decode(Data(contentsOf: golden))
        scan.services = decoded
        scan.connections = edges
        scan.infra = infra
        return scan
    }

    private func edge(_ from: String, _ to: String, _ kind: ScanConnectionKind = .usesInfra) -> ScanConnection {
        ScanConnection(from: from, to: to, kind: kind, label: "\(from) to \(to)")
    }

    @Test func dependencyLayers() throws {
        let scan = try scan(["web", "api", "worker"], edges: [edge("web", "api", .envURL), edge("api", "db"), edge("worker", "db")], infra: [ScanInfra(id: "db", kind: .postgres, usedBy: [], providedBy: nil, evidence: [], host: nil, port: nil)])
        let graph = ServiceGraph(scan: scan)
        #expect(graph.layers == [["db"], ["api", "worker"], ["web"]])
        #expect(graph.edges.map(\.kind) == scan.connections.map(\.kind))
        #expect(graph.edges.map(\.label) == scan.connections.map(\.label))
    }

    @Test func mergesComposeInfra() throws {
        let graph = ServiceGraph(scan: try scan(["api", "compose:db"], edges: [edge("api", "infra:postgres")], infra: [ScanInfra(id: "infra:postgres", kind: .postgres, usedBy: ["api"], providedBy: "compose:db", evidence: [], host: nil, port: nil)]))
        #expect(graph.nodes.count == 2)
        #expect(graph.nodes.first { $0.id == "compose:db" }?.infraKinds == [.postgres])
        #expect(graph.edges[0].to == "compose:db")
        #expect(graph.layers == [["compose:db"], ["api"]])
    }

    @Test func cycleKeepsRealDirections() throws {
        let graph = ServiceGraph(scan: try scan(["a", "b"], edges: [edge("a", "b"), edge("b", "a")]))
        #expect(graph.layers.count == 2)
        #expect(graph.edges.allSatisfy { $0.isCyclic })
        #expect(graph.edges.filter(\.reversedForLayout).count == 1)
        #expect(graph.edges.map(\.from) == ["a", "b"])
        #expect(graph.edges.map(\.to) == ["b", "a"])
    }

    @Test func deterministicPositions() throws {
        let input = try scan(["web", "api", "worker", "db"], edges: [edge("web", "api"), edge("api", "db"), edge("worker", "db")])
        #expect(ServiceGraph(scan: input) == ServiceGraph(scan: input))
    }

    @Test func savedPositionsSurviveRescanAndStorage() throws {
        let position = GraphPosition(x: 73, y: 91)
        var project = Project(folder: URL(filePath: "/tmp/example"), lastResult: try scan(["api", "db"], edges: [edge("api", "db")]))
        project.savedGraphPositions = ["api": position]
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProjectLibraryStore(directory: directory)
        try store.save([project])
        var loaded = try #require(store.load().first)
        loaded.lastResult = try scan(["api", "db", "web"], edges: [edge("api", "db"), edge("web", "api")])
        #expect(loaded.serviceGraph?.positions["api"] == position)
        #expect(loaded.serviceGraph?.positions["web"] != nil)
        project.savedGraphPositions = nil
        let data = try JSONEncoder().encode(project)
        #expect(try JSONDecoder().decode(Project.self, from: data).savedGraphPositions == nil)
    }

    @Test func barycentreReducesCrossings() throws {
        let connections = [edge("e", "d"), edge("f", "c"), edge("g", "b"), edge("h", "a")]
        var graph = ServiceGraph(scan: try scan(["a", "b", "c", "d", "e", "f", "g", "h"], edges: connections))
        ServiceGraphLayout.apply(to: &graph, reduceCrossings: false)
        let dependencies = connections.map { ($0.from, $0.to) }
        let before = ServiceGraphLayout.crossings(graph.layers, dependencies: dependencies)
        ServiceGraphLayout.apply(to: &graph)
        let after = ServiceGraphLayout.crossings(graph.layers, dependencies: dependencies)
        #expect(before == 6)
        #expect(after < before)
    }
}
