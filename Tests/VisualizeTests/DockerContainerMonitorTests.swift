import Foundation
import Testing
@testable import visualize

struct DockerContainerMonitorTests {
    private let id = String(repeating: "a", count: 64)

    private func fixture() -> String {
        """
        {"Id":"\(id)","Name":"/shop-db-1","Config":{"Image":"postgres:16","Labels":{"com.docker.compose.project":"shop","com.docker.compose.service":"db","com.docker.compose.project.working_dir":"/tmp/shop","visualize.owner":"test-owner","visualize.project":"shop-api","visualize.service":"database"}},"State":{"Running":true,"Status":"running"},"NetworkSettings":{"Ports":{"5432/tcp":[{"HostIp":"0.0.0.0","HostPort":"5433"},{"HostIp":"::","HostPort":"5433"}],"80/tcp":null,"53/udp":[{"HostPort":"5353"}]}}}
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

    private func stub(missing: Bool = false, hanging: Bool = false, rowOverride: String? = nil) throws -> StubHelper {
        let row = rowOverride ?? fixture()
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
                    \(missing ? "exit 1" : "printf '%s\\n' '\(row)'") ;;
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
        try monitor.perform("restart", containerID: id, allowedContainerIDs: [id], overridePath: stub.executable.path, dockerOwnership: "test-owner")
        try monitor.perform("stop", containerID: id, allowedContainerIDs: [id], overridePath: stub.executable.path)
        let calls = try String(contentsOf: stub.file("calls"), encoding: .utf8)
        #expect(calls == "ps\ninspect\ninspect\nrestart\ninspect\nstop\n")
    }

    @Test func actionsRejectChangedConfirmationAndForeignOwnership() throws {
        let target = try #require(DockerContainer.decode(Data("[\(fixture())]".utf8)).first)
        for row in [fixture().replacingOccurrences(of: "shop-db-1", with: "renamed-db"),
                    fixture().replacingOccurrences(of: "postgres:16", with: "postgres:17"),
                    fixture().replacingOccurrences(of: "5433", with: "5434")] {
            let helper = try stub(rowOverride: row)
            defer { helper.remove() }
            #expect(throws: (any Error).self) {
                try DockerContainerMonitor().perform("stop", containerID: id, allowedContainerIDs: [id], overridePath: helper.executable.path, expectedContainer: target)
            }
            #expect(try String(contentsOf: helper.file("calls"), encoding: .utf8) == "inspect\n")
        }
        let helper = try stub()
        defer { helper.remove() }
        for token in [nil, "foreign-owner", ""] as [String?] {
            #expect(throws: (any Error).self) {
                try DockerContainerMonitor().perform("restart", containerID: id, allowedContainerIDs: [id], overridePath: helper.executable.path, expectedContainer: target, dockerOwnership: token)
            }
        }
        try DockerContainerMonitor().perform("restart", containerID: id, allowedContainerIDs: [id], overridePath: helper.executable.path, expectedContainer: target, dockerOwnership: "test-owner")
        #expect(try String(contentsOf: helper.file("calls"), encoding: .utf8) == "inspect\ninspect\ninspect\ninspect\nrestart\n")
    }

    @Test @MainActor func storeRejectsStaleConfirmationAndSpoofedRestart() async throws {
        let helper = try stub()
        defer { helper.remove() }
        let target = try #require(DockerContainer.decode(Data("[\(fixture())]".utf8)).first)
        let store = ProcessListenerStore()
        defer { store.stop() }
        store.start(dockerOwnership: "foreign-owner", projects: { [] }, dockerOverride: { helper.executable.path })
        for _ in 0..<100 {
            if store.listeners.contains(where: { $0.container?.id == id }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(store.listeners.contains { $0.container?.id == id })
        let stale = DockerContainer(id: target.id, name: target.name, image: target.image, status: target.status, ports: [9999], labels: target.labels)
        await store.perform("stop", container: stale, overridePath: helper.executable.path)
        #expect(store.actionError?.contains("details changed") == true)
        await store.perform("restart", container: target, overridePath: helper.executable.path)
        #expect(store.actionError?.contains("only restart") == true)
        let calls = try String(contentsOf: helper.file("calls"), encoding: .utf8)
        #expect(!calls.split(separator: "\n").contains("stop"))
        #expect(!calls.split(separator: "\n").contains("restart"))
    }

    @Test func missingContainerRefusesAction() throws {
        let stub = try stub(missing: true)
        defer { stub.remove() }
        #expect(throws: (any Error).self) {
            try DockerContainerMonitor().perform("restart", containerID: id, allowedContainerIDs: [id], overridePath: stub.executable.path, dockerOwnership: "test-owner")
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
            #expect(throws: (any Error).self) {
                try monitor.perform("restart", containerID: containerID, allowedContainerIDs: [containerID], overridePath: nil)
            }
            #expect(monitor.scan(overridePath: nil).contains { $0.id == containerID && $0.status == "running" })
            try monitor.perform("stop", containerID: containerID, allowedContainerIDs: [containerID], overridePath: nil)
            #expect(!monitor.scan(overridePath: nil).contains { $0.id == containerID })
            _ = try await command.run(["rm", containerID], directory: "/tmp")
        } catch {
            _ = try? await command.run(["rm", "-f", containerID], directory: "/tmp")
            throw error
        }
    }

    @Test func refusesStoppedUnpublishedAndUnlistedContainers() throws {
        for row in [fixture().replacingOccurrences(of: "\"Running\":true", with: "\"Running\":false"),
                    fixture().replacingOccurrences(of: "5432/tcp", with: "5432/udp"),
                    fixture().replacingOccurrences(of: id, with: String(repeating: "b", count: 64))] {
            let stub = try stub(rowOverride: row)
            defer { stub.remove() }
            for action in ["stop", "restart"] {
                #expect(throws: (any Error).self) {
                    try DockerContainerMonitor().perform(action, containerID: id, allowedContainerIDs: [id], overridePath: stub.executable.path)
                }
            }
            #expect(try String(contentsOf: stub.file("calls"), encoding: .utf8) == "inspect\ninspect\n")
        }
        let stub = try stub()
        defer { stub.remove() }
        #expect(throws: (any Error).self) {
            try DockerContainerMonitor().perform("stop", containerID: id, allowedContainerIDs: [], overridePath: stub.executable.path)
        }
        #expect(!FileManager.default.fileExists(atPath: stub.file("calls").path))
    }

    @Test @MainActor func storeRefusesContainersNeverDisplayed() async throws {
        let stub = try stub()
        defer { stub.remove() }
        let container = try #require(DockerContainer.decode(Data("[\(fixture())]".utf8)).first)
        let store = ProcessListenerStore()
        await store.perform("stop", container: container, overridePath: stub.executable.path)
        #expect(store.actionError != nil)
        #expect(!FileManager.default.fileExists(atPath: stub.file("calls").path))
    }

    @Test func largeInspectionIsBatchedAndPreservesHealthyContainers() throws {
        let rows = (0..<40).map { index in
            fixture().replacingOccurrences(of: id, with: String(format: "%064x", index + 1))
                .replacingOccurrences(of: "postgres:16", with: String(repeating: "x", count: 40000))
        }
        let stub = try StubHelper { directory in
            let rowsURL = directory.appending(path: "rows")
            return """
            if [ "$1" = context ]; then
                if [ "$2" = show ]; then printf 'default\\n'; else printf '"unix:///test/docker.sock"\\n'; fi
                exit 0
            fi
            shift 2
            if [ "$1" = ps ]; then
                /usr/bin/sed -E 's/^.*"Id":"([^"]+)".*$/\\1/' '\(rowsURL.path)' | while read id; do printf '{"ID":"%s"}\\n' "$id"; done
            else
                shift 3
                printf '%s\\n' "$#" >> '\(directory.path)/batches'
                [ "$#" -le 16 ] || exit 1
                for id in "$@"; do
                    [ "$id" = '0000000000000000000000000000000000000000000000000000000000000001' ] && exit 1
                done
                for id in "$@"; do /usr/bin/awk -v id="$id" 'index($0, id) { print }' '\(rowsURL.path)'; done
            fi
            """
        }
        defer { stub.remove() }
        try (rows.joined(separator: "\n") + "\n").write(to: stub.file("rows"), atomically: true, encoding: .utf8)
        let results = DockerContainerMonitor().scan(overridePath: stub.executable.path)
        #expect(Set(results.map(\.id)) == Set((2...40).map { String(format: "%064x", $0) }))
        let batches = try String(contentsOf: stub.file("batches"), encoding: .utf8).split(separator: "\n").compactMap { Int($0) }
        #expect(batches.allSatisfy { $0 <= 16 })
    }

}
