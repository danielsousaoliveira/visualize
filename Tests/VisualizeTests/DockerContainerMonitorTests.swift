import Foundation
import Testing
@testable import visualize

struct DockerContainerMonitorTests {
    private let id = String(repeating: "a", count: 64)

    private func fixture() -> String {
        """
        {"Id":"\(id)","Name":"/shop-db-1","Config":{"Image":"postgres:16","Labels":{"com.docker.compose.project":"shop","com.docker.compose.service":"db","com.docker.compose.project.working_dir":"/tmp/shop","visualize.project":"shop-api","visualize.service":"database"}},"State":{"Running":true,"Status":"running"},"NetworkSettings":{"Ports":{"5432/tcp":[{"HostIp":"0.0.0.0","HostPort":"5433"},{"HostIp":"::","HostPort":"5433"}],"80/tcp":null,"53/udp":[{"HostPort":"5353"}]}}}
        """
    }

    private func listener(_ name: String, port: Int) -> ProcessListener {
        ProcessListener(port: port, pid: 123, name: name, executablePath: nil, workingDirectory: nil,
                        startedAt: nil, cpuPercent: nil, memoryBytes: nil, projectName: nil, projectFolder: nil, gitBranch: nil)
    }

    @Test func decodesMetadataAndOnlyPublishedTCPPorts() throws {
        let containers = try DockerContainer.decode(Data("[\(fixture())]".utf8))
        let container = try #require(containers.first)
        #expect(container.id == id)
        #expect(container.name == "shop-db-1")
        #expect(container.image == "postgres:16")
        #expect(container.ports == [5433])
        #expect(container.composeProject == "shop")
        #expect(container.composeService == "db")
        #expect(container.workingDirectory == "/tmp/shop")
        #expect(container.visualizeProject == "shop-api")
        #expect(container.visualizeService == "database")
        let hidden = fixture().replacingOccurrences(of: "\"Running\":true", with: "\"Running\":false")
        #expect(try DockerContainer.decode(Data("[\(hidden)]".utf8)).isEmpty)
        let unpublished = fixture().replacingOccurrences(of: "5432/tcp", with: "5432/udp")
        #expect(try DockerContainer.decode(Data("[\(unpublished)]".utf8)).isEmpty)
    }

    @Test func mergesProviderPortsAndPreservesLocalListeners() throws {
        let containers = try DockerContainer.decode(Data("[\(fixture())]".utf8))
        let processes = [listener("com.docker.backend", port: 5433), listener("com.docker.backend", port: 9999), listener("node", port: 3000)]
        let merged = DockerContainerMonitor.merge(processes: processes, containers: containers, projects: [], ports: 1024...65535)
        #expect(merged.map(\.port) == [3000, 5433])
        #expect(merged.last?.container?.id == id)
        #expect(merged.last?.projectName == "shop-api")
        #expect(DockerContainerMonitor.merge(processes: processes, containers: [], projects: [], ports: 1024...65535).map(\.name) == ["node"])
        #expect(DockerContainerMonitor.merge(processes: processes, containers: containers, projects: [], ports: 3000...3000).map(\.port) == [3000])
        #expect(DockerContainerMonitor.merge(processes: processes, containers: containers, projects: [], ports: nil).isEmpty)
    }

    private func stub(missing: Bool = false, hanging: Bool = false) throws -> StubHelper {
        let row = fixture()
        let identity = id
        return try StubHelper { directory in
            """
            if [ "$1" = context ]; then
                if [ "$2" = show ]; then printf 'default\\n'; else printf '"unix:///test/docker.sock"\\n'; fi
                exit 0
            fi
            [ "$1" = --host ] && [ "$2" = unix:///test/docker.sock ] || exit 1
            shift 2
            printf '%s\\n' "$1" >> '\(directory.path)/calls'
            case "$1" in
                ps) \(hanging ? "exec /bin/sleep 60" : "printf '%s\\n' '{\"ID\":\"\(identity)\"}'") ;;
                inspect)
                    [ "$2" = --format ] || exit 2
                    if [ "$3" = '{{.Id}}' ]; then \(missing ? "exit 1" : "printf '%s\\n' '\(identity)'")
                    else printf '%s\\n' '\(row)'; fi ;;
                stop|restart) [ "$2" = '\(identity)' ] && [ "$#" = 2 ] || exit 3 ;;
                *) exit 4 ;;
            esac
            """
        }
    }

    @Test func scansAndActionsUseExactContainerIdentity() throws {
        let stub = try stub()
        defer { stub.remove() }
        let monitor = DockerContainerMonitor()
        #expect(monitor.scan(overridePath: stub.executable.path).first?.image == "postgres:16")
        try monitor.perform("restart", containerID: id, overridePath: stub.executable.path)
        try monitor.perform("stop", containerID: id, overridePath: stub.executable.path)
        let calls = try String(contentsOf: stub.file("calls"), encoding: .utf8)
        #expect(calls == "ps\ninspect\ninspect\nrestart\ninspect\nstop\n")
    }

    @Test func missingContainerRefusesAction() throws {
        let stub = try stub(missing: true)
        defer { stub.remove() }
        #expect(throws: (any Error).self) {
            try DockerContainerMonitor().perform("restart", containerID: id, overridePath: stub.executable.path)
        }
        #expect(try String(contentsOf: stub.file("calls"), encoding: .utf8) == "inspect\n")
    }

    @Test @MainActor func hangingDockerDoesNotDelayProcessScans() async throws {
        let stub = try stub(hanging: true)
        defer { stub.remove() }
        let store = ProcessListenerStore()
        defer { store.stop() }
        store.start(projects: { [] }, dockerOverride: { stub.executable.path })
        try await Task.sleep(for: .milliseconds(1500))
        let initial = try #require(store.lastScan)
        try await Task.sleep(for: .seconds(3))
        #expect(try #require(store.lastScan) > initial)
        #expect(store.listeners.allSatisfy { $0.container == nil })
    }

    @Test func unavailableDockerProducesNoEntries() {
        #expect(DockerContainerMonitor().scan(overridePath: "/missing/docker").isEmpty)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VISUALIZE_DOCKER_TESTS"] == "1"))
    func discoversAndControlsRealPostgres() async throws {
        let command = try DockerCommand.connect(overridePath: nil)
        let data = try await command.run(["run", "--pull", "never", "-d", "--name", "visualize-monitor-test-\(UUID().uuidString.lowercased())",
                                          "-e", "POSTGRES_HOST_AUTH_METHOD=trust", "-p", "127.0.0.1:5433:5432", "postgres:16"], directory: "/tmp")
        let containerID = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let monitor = DockerContainerMonitor()
            let before = try #require(monitor.scan(overridePath: nil).first { $0.id == containerID })
            #expect(before.ports == [5433])
            #expect(before.image == "postgres:16")
            try monitor.perform("restart", containerID: containerID, overridePath: nil)
            #expect(monitor.scan(overridePath: nil).contains { $0.id == containerID && $0.status == "running" })
            try monitor.perform("stop", containerID: containerID, overridePath: nil)
            #expect(!monitor.scan(overridePath: nil).contains { $0.id == containerID })
            _ = try await command.run(["rm", containerID], directory: "/tmp")
        } catch {
            _ = try? await command.run(["rm", "-f", containerID], directory: "/tmp")
            throw error
        }
    }

}
