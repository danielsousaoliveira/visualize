import Foundation
import Testing
@testable import visualize

struct PortAttributionTests {
    private func listener(_ cwd: String) -> ProcessListener {
        ProcessListener(port: 3000, pid: 123, name: "node", executablePath: nil, workingDirectory: cwd,
                        startedAt: nil, cpuPercent: nil, memoryBytes: nil, projectName: "external", projectFolder: nil, gitBranch: nil)
    }

    @Test func deepestServiceAndNestedLibraryWin() throws {
        let scan = try ScanDecoder.decode(Data(contentsOf: ScanDecoderTests.goldenDirectory.appending(path: "scan-pnpm-workspace.json")))
        let project = Project(folder: URL(filePath: "/tmp/shop"), lastResult: scan)
        let web = PortAttribution.resolve(listener("/tmp/shop/apps/web/src"), projects: [project])
        #expect(web.libraryProjectID == project.id)
        #expect(web.serviceName == scan.services.first { $0.rootDirectory == "apps/web" }?.name)
        #expect(web.serviceName != nil)
        #expect(!web.startedByVisualize)
        #expect(PortAttribution.resolve(listener("/tmp/shop"), projects: [project]).serviceName == nil)
        let nested = Project(folder: URL(filePath: "/tmp/shop/apps/web"))
        #expect(PortAttribution.resolve(listener("/tmp/shop/apps/web/src"), projects: [project, nested]).libraryProjectID == nested.id)
        #expect(PortAttribution.resolve(listener("/tmp/shop-other"), projects: [project]).attributionGroup == "Other")
        #expect(PortAttribution.resolve(web, projects: []).attributionGroup == "Other")
    }

    @Test func composeMatchesInsideProjectAndOwnedLabelsWin() throws {
        let scan = try ScanDecoder.decode(Data(contentsOf: ScanDecoderTests.goldenDirectory.appending(path: "scan-compose-env.json")))
        let project = Project(folder: URL(filePath: "/tmp/shop"), lastResult: scan)
        let container = DockerContainer(id: String(repeating: "a", count: 64), name: "db-1", image: "postgres", status: "running", ports: [5432],
            labels: ["com.docker.compose.project.working_dir": "/tmp/shop/subdir", "com.docker.compose.service": "db", "com.docker.compose.project": "shop"])
        let entry = try #require(container.listeners(projects: [project]).first)
        #expect(entry.libraryProjectID == project.id)
        #expect(entry.serviceName == "db")
        #expect(!entry.startedByVisualize)
        #expect(container.listeners(projects: []).first?.attributionGroup == "Other")
        var labels = container.labels
        labels["visualize.project"] = "owned"
        labels["visualize.service"] = "compose:api"
        labels["visualize.library"] = project.id.uuidString
        labels["visualize.owner"] = "installation"
        let owned = DockerContainer(id: container.id, name: container.name, image: container.image, status: container.status, ports: container.ports, labels: labels)
        #expect(owned.listeners(projects: [project], dockerOwnership: "installation").first?.serviceName == "api")
        #expect(owned.listeners(projects: [], dockerOwnership: "installation").first?.startedByVisualize == true)
        #expect(owned.listeners(projects: [project]).first?.startedByVisualize == false)
        #expect(owned.listeners(projects: [project], dockerOwnership: "another-installation").first?.startedByVisualize == false)
        labels.removeValue(forKey: "visualize.owner")
        let spoofed = DockerContainer(id: container.id, name: container.name, image: container.image, status: container.status, ports: container.ports, labels: labels)
        #expect(spoofed.listeners(projects: [project], dockerOwnership: "installation").first?.startedByVisualize == false)
    }

    @Test func composeServiceLabelsSurviveMissingScans() throws {
        let project = Project(folder: URL(filePath: "/tmp/shop"))
        let container = DockerContainer(id: String(repeating: "a", count: 64), name: "db-1", image: "postgres", status: "running", ports: [5432],
            labels: ["com.docker.compose.project.working_dir": "/tmp/shop", "com.docker.compose.service": "db"])
        #expect(container.listeners(projects: [project]).first?.serviceName == "db")
        #expect(container.listeners(projects: []).first?.serviceName == "db")
        var labels = container.labels
        labels["visualize.project"] = "shop"
        labels["visualize.service"] = "database"
        labels["visualize.owner"] = "installation"
        let owned = DockerContainer(id: container.id, name: container.name, image: container.image, status: container.status, ports: container.ports, labels: labels)
        #expect(owned.listeners(projects: [], dockerOwnership: "installation").first?.serviceName == "database")
        #expect(owned.listeners(projects: [], dockerOwnership: "foreign").first?.serviceName == "db")
    }

    @Test func groupsProjectsByIdentityRatherThanName() throws {
        var first = listener("/tmp/first")
        first.libraryProjectID = UUID()
        first.projectName = "Other"
        var second = listener("/tmp/second")
        second.libraryProjectID = UUID()
        second.projectName = "Other"
        var anotherPort = first
        anotherPort.serviceName = "web"
        let external = listener("/tmp/external")
        let groups = ProcessListenerGroup.groups([first, second, anotherPort, external])
        #expect(groups.count == 3)
        #expect(groups.allSatisfy { $0.name == "Other" })
        let firstID = try #require(first.libraryProjectID)
        let secondID = try #require(second.libraryProjectID)
        #expect(groups.first { $0.id == "library:\(firstID.uuidString)" }?.listeners.count == 2)
        #expect(groups.first { $0.id == "library:\(secondID.uuidString)" }?.listeners.count == 1)
        #expect(groups.first { $0.id == "other" }?.listeners.count == 1)
    }

    @Test @MainActor func monitorReceivesStoredOwnershipTokenByDefault() {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let state = AppState(store: ProjectLibraryStore(directory: root))
        defer {
            state.listenerStore.stop()
            try? FileManager.default.removeItem(at: root)
        }
        #expect(!state.dockerOwnership.isEmpty)
        #expect(state.listenerStore.dockerOwnership == state.dockerOwnership)
    }

    @Test func externalManifestNameAndFolderFallback() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appending(path: "src"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(PortAttribution.externalName(directory: root.path) == root.lastPathComponent)
        try Data(#"{"name":"outside-web"}"#.utf8).write(to: root.appending(path: "package.json"))
        #expect(PortAttribution.externalName(directory: root.appending(path: "src").path) == "outside-web")
    }
}
