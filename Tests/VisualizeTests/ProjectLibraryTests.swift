import Foundation
import Testing
@testable import visualize

@MainActor
struct ProjectLibraryTests {
    static let nodeGolden = ScanDecoderTests.goldenDirectory.appending(path: "deploy-node.json")
    static let composeGolden = ScanDecoderTests.goldenDirectory.appending(path: "scan-compose-env.json")

    let stub: StubHelper
    let store: ProjectLibraryStore

    init() throws {
        stub = try StubHelper { dir in
            """
            if [ -f '\(dir.path)/fail' ]; then echo 'visualize-scan: Permission denied' >&2; exit 1; fi
            cat '\(dir.path)/output.json'
            """
        }
        store = ProjectLibraryStore(directory: stub.file("support"))
        try respond(with: Self.nodeGolden)
    }

    func makeState() -> AppState {
        AppState(scanHelper: ScanHelper(executableURL: stub.executable), store: store)
    }

    func makeFolder(_ name: String) throws -> URL {
        let folder = stub.file("repos/\(name)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "keep".write(to: folder.appending(path: "README"), atomically: true, encoding: .utf8)
        return folder
    }

    func respond(with golden: URL) throws {
        let output = stub.file("output.json")
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.copyItem(at: golden, to: output)
    }

    func setFailing(_ failing: Bool) throws {
        let flag = stub.file("fail")
        if failing {
            try Data().write(to: flag)
        } else {
            try? FileManager.default.removeItem(at: flag)
        }
    }

    @Test func keepsProjectsAndResultsAcrossRelaunch() async throws {
        defer { stub.remove() }
        let state = makeState()
        await state.addProject(folder: try makeFolder("alpha"))
        await state.addProject(folder: try makeFolder("beta"))

        let relaunched = makeState()

        #expect(relaunched.projects.map(\.name) == ["alpha", "beta"])
        #expect(relaunched.projects.allSatisfy { $0.lastResult?.project.name == "hello-node" })
        #expect(relaunched.libraryError == nil)
    }

    @Test func scansProjectsLeftWithoutAResultOnRelaunch() async throws {
        defer { stub.remove() }
        let unscanned = Project(folder: try makeFolder("alpha"))
        let missing = Project(folder: stub.file("repos/gone"))
        let scanned = Project(folder: try makeFolder("beta"), lastResult: try ScanDecoder.decode(Data(contentsOf: Self.nodeGolden)))
        try store.save([unscanned, missing, scanned])
        try respond(with: Self.composeGolden)

        let relaunched = makeState()
        await relaunched.scanProjectsWithoutResults()

        #expect(relaunched.project(unscanned.id)?.lastResult?.project.type == .services)
        #expect(relaunched.project(missing.id)?.lastResult == nil)
        #expect(relaunched.scanErrors[missing.id] == nil)
        #expect(relaunched.project(scanned.id)?.lastResult?.project.name == "hello-node")
        #expect(try store.load().first?.lastResult?.project.type == .services)
    }

    @Test func selectsTheExistingEntryForADuplicateFolder() async throws {
        defer { stub.remove() }
        let state = makeState()
        let folder = try makeFolder("alpha")
        await state.addProject(folder: folder)
        let original = try #require(state.projects.first)
        await state.addProject(folder: try makeFolder("beta"))

        await state.addProject(folder: folder.appending(path: "../alpha/", directoryHint: .isDirectory))

        #expect(state.projects.count == 2)
        #expect(state.selection == original.id)
        #expect(try store.load().count == 2)
    }

    @Test func rescanReplacesTheStoredResult() async throws {
        defer { stub.remove() }
        let state = makeState()
        await state.addProject(folder: try makeFolder("alpha"))
        let id = try #require(state.selection)
        try respond(with: Self.composeGolden)

        await state.rescan(id)

        #expect(state.project(id)?.lastResult?.project.type == .services)
        #expect(try store.load().first?.lastResult?.project.type == .services)
    }

    @Test func removeDropsTheProjectButLeavesTheFolder() async throws {
        defer { stub.remove() }
        let state = makeState()
        let folder = try makeFolder("alpha")
        await state.addProject(folder: folder)
        let id = try #require(state.selection)

        state.remove(id)

        #expect(state.projects.isEmpty)
        #expect(state.selection == nil)
        #expect(try store.load().isEmpty)
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "README").path))
    }

    @Test func locateRestoresAMovedFolder() async throws {
        defer { stub.remove() }
        let state = makeState()
        let folder = try makeFolder("alpha")
        await state.addProject(folder: folder)
        let id = try #require(state.selection)
        let moved = stub.file("repos/alpha-renamed")
        try FileManager.default.moveItem(at: folder, to: moved)

        let relaunched = makeState()
        #expect(relaunched.project(id)?.folderExists == false)

        await relaunched.locate(id, at: moved)

        let project = try #require(relaunched.project(id))
        #expect(project.folderExists)
        #expect(project.name == "alpha-renamed")
        #expect(project.folderPath == Project.canonicalPath(of: moved))
        #expect(try store.load().first?.folderPath == project.folderPath)
    }

    @Test func aFailedRescanKeepsThePreviousResult() async throws {
        defer { stub.remove() }
        let state = makeState()
        await state.addProject(folder: try makeFolder("alpha"))
        let id = try #require(state.selection)
        try setFailing(true)

        await state.rescan(id)

        #expect(state.project(id)?.lastResult?.project.name == "hello-node")
        #expect(state.scanErrors[id]?.contains("Permission denied") == true)
        #expect(try store.load().first?.lastResult?.project.name == "hello-node")

        try setFailing(false)
        await state.rescan(id)
        #expect(state.scanErrors[id] == nil)
    }

    @Test func loadsAResultSavedBeforeInfraAndEnvWereDecoded() throws {
        defer { stub.remove() }
        var result = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: Self.composeGolden)) as? [String: Any])
        result.removeValue(forKey: "infra")
        result.removeValue(forKey: "envRequirements")
        let project: [String: Any] = [
            "id": UUID().uuidString,
            "name": "old",
            "folderPath": "/tmp/old",
            "lastResult": result,
        ]
        try FileManager.default.createDirectory(at: stub.file("support"), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["version": 1, "projects": [project]]).write(to: store.fileURL)

        let projects = try store.load()

        #expect(projects.map(\.name) == ["old"])
        #expect(projects.first?.lastResult?.infra == [])
        #expect(projects.first?.lastResult?.envRequirements == [])
        #expect(projects.first?.lastResult?.services.count == 3)
    }

    @Test func loadsAResultSavedBeforeConnectionsAndInfraIds() throws {
        defer { stub.remove() }
        var result = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: Self.composeGolden)) as? [String: Any])
        let infra = try #require(result["infra"] as? [[String: Any]])
        result["infra"] = infra.map { entry in entry.filter { $0.key != "id" } }
        result.removeValue(forKey: "connections")
        let project: [String: Any] = [
            "id": UUID().uuidString,
            "name": "old",
            "folderPath": "/tmp/old",
            "lastResult": result,
        ]
        try FileManager.default.createDirectory(at: stub.file("support"), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["version": 1, "projects": [project]]).write(to: store.fileURL)

        let projects = try store.load()

        #expect(projects.first?.lastResult?.connections == [])
        #expect(projects.first?.lastResult?.infra.map(\.id) == ["infra:postgres", "infra:redis"])
    }

    @Test func numbersMissingInfraIdsPerKindLikeTheHelper() {
        let entry = { (kind: ScanInfraKind) in
            ScanInfra(id: "", kind: kind, usedBy: [], providedBy: nil, evidence: ["e"], host: nil, port: nil)
        }
        let filled = [entry(.postgres), entry(.postgres), entry(.redis), entry(.postgres)].fillingMissingIds()
        #expect(filled.map(\.id) == ["infra:postgres", "infra:postgres-2", "infra:redis", "infra:postgres-3"])
    }

    @Test func movesAnUnreadableLibraryAsideInsteadOfOverwritingIt() throws {
        defer { stub.remove() }
        try FileManager.default.createDirectory(at: stub.file("support"), withIntermediateDirectories: true)
        try "{ not json".write(to: store.fileURL, atomically: true, encoding: .utf8)

        let state = makeState()

        #expect(state.projects.isEmpty)
        #expect(state.libraryError?.contains("could not be read") == true)
        let backups = try FileManager.default.contentsOfDirectory(atPath: stub.file("support").path)
            .filter { $0.hasPrefix("library.unreadable-") }
        #expect(backups.count == 1)
    }
    @Test func graphMovesPersistThroughRescanAndRelaunch() async throws {
        defer { stub.remove() }
        let state = makeState()
        defer { state.listenerStore.stop() }
        await state.addProject(folder: try makeFolder("graph"))
        let project = try #require(state.projects.first)
        let nodeID = try #require(project.lastResult?.services.first?.id)
        let model = try #require(state.graphModel(projectID: project.id))
        let position = GraphPosition(x: 71, y: 95)
        model.moveNode(nodeID, to: position)
        #expect(model.graph.positions[nodeID] == position)
        #expect(try store.load().first?.savedGraphPositions?[nodeID] == position)
        model.moveNode("missing", to: position)
        model.moveNode(nodeID, to: GraphPosition(x: .infinity, y: 0))
        #expect(try store.load().first?.savedGraphPositions == [nodeID: position])
        var scan = try #require(project.lastResult)
        var added = try #require(scan.services.first)
        added.id = "new-node"
        added.name = "New node"
        scan.services.append(added)
        try JSONEncoder().encode(scan).write(to: stub.file("output.json"))
        await state.rescan(project.id)
        #expect(state.graphModel(projectID: project.id) === model)
        #expect(model.graph.positions[nodeID] == position)
        #expect(model.graph.positions["new-node"] != nil)
        let relaunched = makeState()
        defer { relaunched.listenerStore.stop() }
        #expect(relaunched.graphModel(projectID: project.id)?.graph.positions[nodeID] == position)
    }

}
