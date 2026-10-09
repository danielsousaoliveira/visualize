import Darwin
import Foundation
import Testing
@testable import visualize

@Suite(.serialized)
struct ProjectRunnerTests {
    @MainActor private func fixture() throws -> (AppState, Project, URL) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "project-run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var result = try ScanDecoder.decode(Data(contentsOf: ScanDecoderTests.goldenDirectory.appending(path: "scan-compose-env.json")))
        let template = try #require(result.services.first)
        result.services = ["db", "api", "web"].map { name in
            var service = template
            service.id = name
            service.name = name
            service.rootDirectory = "."
            service.port = nil
            service.devCommand = ScanDevCommand(argv: ["/bin/sleep", "60"], workingDirectory: ".", source: "test")
            service.runModes = ScanRunModes(local: ScanRunMode(available: true, reason: nil), compose: ScanComposeRunMode(available: false, reason: nil, composeFile: nil, serviceName: nil), dockerfile: ScanDockerfileRunMode(available: false, reason: nil, dockerfilePath: nil, containerPort: nil))
            return service
        }
        result.infra = []
        result.connections = [ScanConnection(from: "web", to: "api", kind: .envURL, label: "API_URL"), ScanConnection(from: "api", to: "db", kind: .dependsOn, label: "depends_on")]
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let paths = [".build/out/Products/Debug/visualize", ".build/debug/visualize"]
        let drainer = try #require(paths.map { root.appending(path: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) })
        let state = AppState(store: ProjectLibraryStore(directory: folder.appending(path: "library")), outputDrainerURL: drainer)
        return (state, Project(folder: folder, lastResult: result), folder)
    }

    @Test @MainActor func preservesRunningPIDAndStopsProject() async throws {
        let (state, project, folder) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try #require(project.lastResult?.services.first)
        await state.start(project: project, service: db, recipe: try #require(state.recipe(project: project, service: db)))
        let pid = try #require(state.serviceRuns[state.runKey(project: project, service: db)]?.pid)
        let group = try #require(state.serviceRuns[state.runKey(project: project, service: db)]?.group)
        let listener = ProcessListener(port: 3000, pid: pid, name: "sleep", executablePath: nil, workingDirectory: "/",
            startedAt: ProcessIdentity(pid: pid, seconds: group.seconds, microseconds: group.microseconds),
            cpuPercent: nil, memoryBytes: nil, projectName: nil, projectFolder: nil, gitBranch: nil)
        let attribution = try #require(state.ownedAttribution(listener))
        #expect(attribution.startedByVisualize)
        #expect(attribution.serviceName == db.name)
        #expect(attribution.libraryProjectID == project.id)
        await state.startAll(project: project, mode: .configured)
        #expect(state.serviceRuns[state.runKey(project: project, service: db)]?.pid == pid)
        #expect(state.projectOperations[project.id]?.order == ["db", "api", "web"])
        #expect(state.projectOperations[project.id]?.statuses["db"] == "already running")
        var rescanned = project
        rescanned.lastResult?.services = []
        await state.stopAll(project: rescanned)
        #expect(state.projectOperations[project.id]?.order == ["web", "api", "db"])
        #expect(!state.hasOwnedProcesses)
    }

    @Test @MainActor func showsStoppingThenStoppedForStopAll() async throws {
        let (state, original, folder) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        var project = original
        project.lastResult?.services = Array(original.lastResult?.services.prefix(1) ?? [])
        project.lastResult?.connections = []
        project.lastResult?.services[0].devCommand?.argv = ["/usr/bin/perl", "-e", "$SIG{TERM} = 'IGNORE'; open my $ready, '>', 'ready' or die $!; close $ready; sleep 30;"]
        let service = try #require(project.lastResult?.services.first)
        await state.start(project: project, service: service, recipe: try #require(state.recipe(project: project, service: service)), storedEnvironment: ["PATH": "/usr/bin:/bin"])
        let readyPath = folder.appending(path: "ready").path
        let readyDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !FileManager.default.fileExists(atPath: readyPath), ContinuousClock.now < readyDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(FileManager.default.fileExists(atPath: readyPath))
        let stop = Task { await state.stopAll(project: project) }
        let stoppingDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while state.projectOperations[project.id]?.statuses[service.id] != "stopping", ContinuousClock.now < stoppingDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(state.projectOperations[project.id]?.statuses[service.id] == "stopping")
        await stop.value
        #expect(state.projectOperations[project.id]?.statuses[service.id] == "stopped")
        #expect(!state.hasOwnedProcesses)
    }

    @Test @MainActor func blocksDependentsAfterStartFailure() async throws {
        let (state, original, folder) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let previous = state.dockerOverridePath
        state.dockerOverridePath = nil
        defer { state.dockerOverridePath = previous }
        var project = original
        project.lastResult?.services[1].devCommand?.argv = ["/usr/bin/false"]
        project.lastResult?.services[1].port = 49991
        await state.startAll(project: project, mode: .local)
        #expect(state.projectOperations[project.id]?.statuses["web"] == "blocked by api")
        #expect(state.serviceRuns["\(project.id.uuidString):web"] == nil)
        await state.stopAll(project: project)
        #expect(!state.hasOwnedProcesses)
    }

    @Test @MainActor func startsCycleTogetherAndWarns() async throws {
        let (state, original, folder) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        var project = original
        project.lastResult?.connections.append(ScanConnection(from: "db", to: "api", kind: .dependsOn, label: "depends_on"))
        await state.startAll(project: project, mode: .local)
        #expect(state.projectOperations[project.id]?.warnings.count == 1)
        #expect(state.projectOperations[project.id]?.statuses.values.allSatisfy { $0 == "running" } == true)
        await state.stopAll(project: project)
        #expect(!state.hasOwnedProcesses)
    }


    @Test @MainActor func waitsForTCPBeforeStartingDependents() async throws {
        let (state, original, folder) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let previous = state.dockerOverridePath
        state.dockerOverridePath = nil
        defer { state.dockerOverridePath = previous }
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw NSError(domain: "test socket", code: 1) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &length) }
        }
        close(socketFD)
        #expect(bound == 0 && named == 0)
        let port = Int(UInt16(bigEndian: address.sin_port))
        var project = original
        project.lastResult?.services[0].port = port
        project.lastResult?.services[0].devCommand?.argv = ["/bin/sh", "-c", "sleep 1; exec /usr/bin/nc -lk 127.0.0.1 \(port)"]
        let run = Task { await state.startAll(project: project, mode: .local) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while state.projectOperations[project.id]?.statuses["db"] != "running", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(state.serviceRuns["\(project.id.uuidString):api"] == nil)
        await run.value
        #expect(state.projectOperations[project.id]?.statuses["api"] == "running", "\(state.projectOperations[project.id]?.statuses ?? [:])")
        #expect(TCPProbe.accepts(port: port))
        await state.stopAll(project: project)
        #expect(!state.hasOwnedProcesses)
    }

    @Test @MainActor func batchesComposeWithoutFallingBackToLocal() async throws {
        let (state, original, folder) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        var project = original
        for index in 0..<2 {
            project.lastResult?.services[index].runModes.compose = ScanComposeRunMode(available: true, reason: nil, composeFile: "compose.yaml", serviceName: index == 0 ? "db" : "api")
        }
        try "services: {}".write(to: folder.appending(path: "compose.yaml"), atomically: true, encoding: .utf8)
        let stub = try StubHelper { dir in
            """
            printf '%s\\n' "$*" >> '\(dir.path)/calls'
            case "$*" in
              'context show') printf 'test\\n';;
              'context inspect '*) printf '"unix:///test/docker.sock"\\n';;
              *' info '*) printf '{}\\n';;
              *'compose version'*) printf '2.30.0\\n';;
              *' up '*) touch '\(dir.path)/started';;
              *'compose '*' ps '*) printf 'db-id\\napi-id\\n';;
              *'inspect --format'*) printf '\(state.dockerOwnership) \(project.id.uuidString)\\n';;
              *'--filter label=com.docker.compose.project='*)
                if [ -f '\(dir.path)/started' ]; then
                  [ -f '\(dir.path)/stopped-db' ] || printf 'db-id\\tdb\\n'
                  [ -f '\(dir.path)/stopped-api' ] || printf 'api-id\\tapi\\n'
                fi;;
              *' stop db') touch '\(dir.path)/stopped-db';;
              *' stop api') touch '\(dir.path)/stopped-api';;
              *' rm '*) :;;
              *) exit 1;;
            esac
            exit 0
            """
        }
        defer { stub.remove() }
        let previous = state.dockerOverridePath
        state.dockerOverridePath = stub.executable.path
        defer { state.dockerOverridePath = previous }
        await state.checkDocker()
        await state.startAll(project: project, mode: .docker)
        #expect(state.projectOperations[project.id]?.statuses["db"] == "running")
        #expect(state.projectOperations[project.id]?.statuses["api"] == "running")
        #expect(state.projectOperations[project.id]?.statuses["web"] == "unavailable — no matching run mode")
        let calls = try String(contentsOf: stub.file("calls"), encoding: .utf8).split(separator: "\n").map(String.init)
        let ups = calls.filter { $0.contains(" up ") }
        #expect(ups.count == 1)
        #expect(ups.first?.contains("--no-deps --no-recreate db api") == true)
        #expect(state.serviceRuns["\(project.id.uuidString):web"] == nil)
        await state.stopAll(project: project)
        #expect(!state.hasOwnedProcesses)
        let stopped = try String(contentsOf: stub.file("calls"), encoding: .utf8)
        #expect(stopped.contains(" rm api-id"))
        #expect(stopped.contains(" rm db-id"))
    }

    @Test @MainActor func resolvesOnlySupportedRequestedModes() throws {
        let (_, project, folder) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        var service = try #require(project.lastResult?.services.first)
        #expect(ProjectStartMode.docker.resolve(service, remembered: .local) == nil)
        service.runModes.compose = ScanComposeRunMode(available: true, reason: nil, composeFile: "compose.yaml", serviceName: "db")
        #expect(ProjectStartMode.docker.resolve(service, remembered: .local) == .compose)
        #expect(ProjectStartMode.configured.resolve(service, remembered: .local) == .local)
        service.runModes.local.available = false
        #expect(ProjectStartMode.local.resolve(service, remembered: .compose) == nil)
    }
    @Test @MainActor func widgetBulkStopLeavesUndisplayedServicesRunning() async throws {
        let (state, original, folder) = try fixture()
        defer {
            state.listenerStore.stop()
            try? FileManager.default.removeItem(at: folder)
        }
        var project = original
        let portFile = folder.appending(path: "port")
        project.lastResult?.services[0].devCommand?.argv = ["/usr/bin/perl", "-MIO::Socket::INET", "-e", "my $s = IO::Socket::INET->new(LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 1) or die $!; open my $f, '>', $ARGV[0] or die $!; print $f $s->sockport; close $f; sleep 60;", portFile.path]
        let displayed = try #require(project.lastResult?.services[0])
        let hidden = try #require(project.lastResult?.services[1])
        for service in [displayed, hidden] {
            await state.start(project: project, service: service, recipe: try #require(state.recipe(project: project, service: service)), storedEnvironment: ["PATH": "/usr/bin:/bin"])
        }
        let displayedRun = try #require(state.serviceRuns[state.runKey(project: project, service: displayed)])
        let hiddenRun = try #require(state.serviceRuns[state.runKey(project: project, service: hidden)])
        defer {
            _ = displayedRun.group?.signal(SIGKILL)
            _ = hiddenRun.group?.signal(SIGKILL)
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !FileManager.default.fileExists(atPath: portFile.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let port = try #require(Int(String(contentsOf: portFile, encoding: .utf8)))
        state.listenerStore.lowerPort = port
        state.listenerStore.upperPort = port
        while !state.listenerStore.listeners.contains(where: { $0.pid == displayedRun.pid }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let listener = try #require(state.listenerStore.listeners.first { $0.pid == displayedRun.pid })
        let group = ProcessListenerGroup(id: "library:\(project.id)", name: project.name, listeners: [listener])
        #expect(state.widgetStopManagedAvailable(group))
        await state.widgetStopManaged(group)
        #expect(!displayedRun.active)
        #expect(hiddenRun.active)
        #expect(hiddenRun.group?.exists == true)
        await state.stopAll(project: project)
    }

}
