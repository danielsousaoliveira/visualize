import Foundation
import Testing
@testable import visualize

struct ProjectRunPlanTests {
    @Test func ordersDependenciesAndParallelPeers() {
        let plan = ProjectRunPlan(ids: ["web", "api", "db", "cache"], dependencies: ["web": ["api"], "api": ["db", "cache"]])
        #expect(plan.layers == [[["db"], ["cache"]], [["api"]], [["web"]]])
        #expect(plan.cycles.isEmpty)
    }

    @Test func isolatesCyclesFromTheirDependents() {
        let plan = ProjectRunPlan(ids: ["web", "a", "b", "db"], dependencies: ["web": ["a"], "a": ["b", "db"], "b": ["a"]])
        #expect(plan.layers == [[["db"]], [["a", "b"]], [["web"]]])
        #expect(plan.cycles == [["a", "b"]])
    }

    @Test func ignoresUnknownTargetsAndHandlesSelfCycle() {
        let plan = ProjectRunPlan(ids: ["a", "b"], dependencies: ["a": ["a", "external"], "b": ["a"]])
        #expect(plan.layers == [[["a"]], [["b"]]])
        #expect(plan.dependencies["a"] == ["a"])
        #expect(plan.cycles == [["a"]])
    }

    @Test func resolvesInfraAndURLConnections() throws {
        var result = try ScanDecoder.decode(Data(contentsOf: ScanDecoderTests.goldenDirectory.appending(path: "scan-compose-env.json")))
        let ids = Array(result.services.prefix(3).map(\.id))
        #expect(ids.count == 3)
        result.services = Array(result.services.prefix(3))
        result.infra = [ScanInfra(id: "infra:db", kind: .postgres, usedBy: [ids[1]], providedBy: ids[2], evidence: [], host: "localhost", port: 5432)]
        result.connections = [ScanConnection(from: ids[0], to: ids[1], kind: .envURL, label: "API_URL"), ScanConnection(from: ids[1], to: "infra:db", kind: .usesInfra, label: "postgres")]
        let plan = ProjectRunPlan(result: result)
        #expect(plan.layers == [[[ids[2]]], [[ids[1]]], [[ids[0]]]])
    }
}
