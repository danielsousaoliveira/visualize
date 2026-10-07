import Foundation
import Testing
@testable import visualize

struct DockerServiceTests {
    @Test func confinesPathsAndSeparatesProjectNames() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let folder = root.appending(path: "repo")
        let outside = root.appending(path: "outside")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: folder.appending(path: "escape"), withDestinationURL: outside)
        try Data().write(to: outside.appending(path: "Dockerfile"))
        let project = Project(folder: folder)
        #expect(try DockerPath.resolve(".", project: project).path == Project.canonicalPath(of: folder))
        #expect(throws: NSError.self) { try DockerPath.resolve("../outside", project: project) }
        #expect(throws: NSError.self) { try DockerPath.resolve("escape/Dockerfile", project: project) }
        #expect(throws: NSError.self) { try DockerPath.resolve(outside.path, project: project) }
        #expect(DockerRun.projectSlug(project) != DockerRun.projectSlug(Project(folder: folder)))
    }

    @Test @MainActor func refusesStopWithoutContainerIdentity() async {
        let state = AppState(store: ProjectLibraryStore(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)))
        let run = ServiceRun(recipe: RunRecipe(argv: [], workingDirectory: "/tmp", addedEnvironmentKeys: [], startedAt: Date()))
        run.docker = DockerRun(command: DockerCommand(executable: "/usr/bin/false", endpoint: "unix:///missing"), mode: .dockerfile, projectID: UUID(), projectSlug: "test", serviceName: "api", composeArguments: [], containerIDs: [])
        #expect(state.hasOwnedProcesses == false)
        #expect(await state.stopDocker(run) == false)
        #expect(run.active)
        #expect(run.status == "Stop failed: Container identity unavailable; Docker action refused")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VISUALIZE_DOCKER_TESTS"] == "1"))
    @MainActor func managesComposeDependenciesAndDockerfileContainers() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "visualize-docker-test-\(UUID().uuidString.lowercased())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try """
        services:
          db:
            image: postgres:16
            environment:
              POSTGRES_HOST_AUTH_METHOD: trust
          api:
            image: alpine:latest
            command: [sleep, '300']
            depends_on: [db]
        """.write(to: folder.appending(path: "compose.yaml"), atomically: true, encoding: .utf8)
        var result = try ScanDecoder.decode(Data(contentsOf: ScanDecoderTests.goldenDirectory.appending(path: "scan-compose-env.json")))
        result.services = result.services.filter { $0.name == "api" || $0.name == "db" }.map { original in
            var service = original
            service.runModes.compose = ScanComposeRunMode(available: true, reason: nil, composeFile: "compose.yaml", serviceName: service.name)
            return service
        }
        let project = Project(folder: folder, lastResult: result)
        let store = ProjectLibraryStore(directory: folder.appending(path: "library"))
        let state = AppState(store: store)
        let command = try DockerCommand.connect(overridePath: nil)
        let slug = DockerRun.projectSlug(project)
        defer {
            let prefix = ["--host", command.endpoint]
            if let remaining = try? CommandOutput.run(command.executable, arguments: prefix + ["ps", "-a", "-q", "--filter", "label=visualize.library=\(project.id.uuidString)"]) {
                let ids = String(decoding: remaining.data, as: UTF8.self).split(whereSeparator: \.isWhitespace).map(String.init)
                if !ids.isEmpty { _ = try? CommandOutput.run(command.executable, arguments: prefix + ["rm", "-f", "-v"] + ids) }
            }
            _ = try? CommandOutput.run(command.executable, arguments: prefix + ["network", "rm", "\(slug)_default"])
            _ = try? CommandOutput.run(command.executable, arguments: prefix + ["image", "rm", "visualize/\(slug)-api:dev"])
            for id in result.services.map(\.id) + ["api"] {
                UserDefaults.standard.removeObject(forKey: "serviceMode.\(project.id.uuidString):\(id)")
            }
        }
        let api = try #require(result.services.first { $0.name == "api" })
        let db = try #require(result.services.first { $0.name == "db" })
        await state.checkDocker()
        #expect(state.dockerState.unavailableReason(compose: true) == nil)
        state.setMode(.compose, project: project, service: api)
        await state.startDocker(project: project, service: api)
        let apiRun = try #require(state.serviceRuns[state.runKey(project: project, service: api)])
        let dbRun = try #require(state.serviceRuns[state.runKey(project: project, service: db)])
        #expect(apiRun.active, "\(apiRun.status)\n\(apiRun.lastOutputLines)")
        #expect(dbRun.active)
        #expect(state.hasOwnedProcesses)
        let dbID = try #require(dbRun.docker?.containerIDs.first)
        let labels = try await command.run(["inspect", "--format", "{{index .Config.Labels \"com.docker.compose.project\"}} {{index .Config.Labels \"visualize.service\"}}", dbID], directory: folder.path)
        #expect(String(decoding: labels, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "\(slug) \(db.id)")
        await state.stop(project: project, service: db)
        #expect(!dbRun.active)
        let stopped = try await command.run(["ps", "--filter", "id=\(dbID)", "--format", "{{.ID}}"], directory: folder.path)
        #expect(stopped.isEmpty)
        let relaunched = AppState(store: store)
        #expect(relaunched.dockerOwnership == state.dockerOwnership)
        await relaunched.checkDocker()
        await relaunched.startDocker(project: project, service: db)
        let recoveredDB = try #require(relaunched.serviceRuns[relaunched.runKey(project: project, service: db)])
        #expect(recoveredDB.active, "\(recoveredDB.status)")
        let foreignSession = AppState(store: store, dockerOwnership: UUID().uuidString)
        await foreignSession.checkDocker()
        await foreignSession.startDocker(project: project, service: db)
        let refused = try #require(foreignSession.serviceRuns[foreignSession.runKey(project: project, service: db)])
        #expect(!refused.active)
        #expect(refused.status.contains("refused"))
        #expect(await relaunched.stopForQuit())
        #expect(!relaunched.hasOwnedProcesses)
        await relaunched.restart(project: project, service: db)
        #expect(recoveredDB.active)
        #expect(await relaunched.stopForQuit())
        try "FROM alpine:latest\nEXPOSE 8080\nCMD [\"sleep\", \"300\"]\n".write(to: folder.appending(path: "Dockerfile"), atomically: true, encoding: .utf8)
        var dockerService = api
        dockerService.id = "api"
        dockerService.rootDirectory = "."
        dockerService.port = 49187
        dockerService.runModes.dockerfile = ScanDockerfileRunMode(available: true, reason: nil, dockerfilePath: "Dockerfile", containerPort: 8080)
        state.setMode(.dockerfile, project: project, service: dockerService)
        #expect(AppState(store: store).mode(project: project, service: dockerService) == .dockerfile)
        await state.startDocker(project: project, service: dockerService)
        let builtRun = try #require(state.serviceRuns[state.runKey(project: project, service: dockerService)])
        #expect(builtRun.active, "\(builtRun.status)\n\(builtRun.lastOutputLines)")
        let builtID = try #require(builtRun.docker?.containerIDs.first)
        let port = try await command.run(["port", builtID, "8080"], directory: folder.path)
        #expect(String(decoding: port, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "127.0.0.1:49187")
        let recovered = AppState(store: store)
        await recovered.checkDocker()
        await recovered.startDocker(project: project, service: dockerService)
        let recoveredRun = try #require(recovered.serviceRuns[recovered.runKey(project: project, service: dockerService)])
        #expect(recoveredRun.active)
        #expect(recoveredRun.docker?.containerIDs.first == builtID)
        #expect(recovered.hasOwnedProcesses)
        let recorded = try #require(recoveredRun.docker)
        var missingIdentity = recorded
        missingIdentity.containerIDs = []
        recoveredRun.docker = missingIdentity
        #expect(await recovered.stopForQuit() == false)
        #expect(recovered.hasOwnedProcesses)
        recoveredRun.docker = recorded
        #expect(await recovered.stopForQuit())
        #expect(!recovered.hasOwnedProcesses)
        let removed = try await command.run(["ps", "-a", "--filter", "id=\(builtID)", "--format", "{{.ID}}"], directory: folder.path)
        #expect(removed.isEmpty)
        await recovered.restart(project: project, service: dockerService)
        let restarted = try #require(recovered.serviceRuns[recovered.runKey(project: project, service: dockerService)])
        #expect(restarted.active)
        #expect(restarted.docker?.containerIDs.first != builtID)
        let stoppedID = try #require(restarted.docker?.containerIDs.first)
        _ = try await command.run(["stop", stoppedID], directory: folder.path)
        let afterCrash = AppState(store: store)
        await afterCrash.checkDocker()
        await afterCrash.startDocker(project: project, service: dockerService)
        let rebuilt = try #require(afterCrash.serviceRuns[afterCrash.runKey(project: project, service: dockerService)])
        #expect(rebuilt.active)
        #expect(rebuilt.docker?.containerIDs.first != stoppedID)
        #expect(await afterCrash.stopForQuit())
        let foreign = try await command.run(["run", "-d", "--name", "visualize-\(slug)-api", "--label", "visualize.library=\(project.id.uuidString)", "alpine:latest", "sleep", "300"], directory: folder.path)
        let foreignID = String(decoding: foreign, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        await afterCrash.startDocker(project: project, service: dockerService)
        let conflict = try #require(afterCrash.serviceRuns[afterCrash.runKey(project: project, service: dockerService)])
        #expect(!conflict.active)
        #expect(conflict.status.contains("already in use"))
        let stillRunning = try await command.run(["inspect", "--format", "{{.State.Running}}", foreignID], directory: folder.path)
        #expect(String(decoding: stillRunning, as: UTF8.self).contains("true"))
        _ = try await command.run(["rm", "-f", foreignID], directory: folder.path)
        try "INVALID instruction\n".write(to: folder.appending(path: "Dockerfile"), atomically: true, encoding: .utf8)
        await afterCrash.startDocker(project: project, service: dockerService)
        let failed = try #require(afterCrash.serviceRuns[afterCrash.runKey(project: project, service: dockerService)])
        #expect(!failed.active)
        #expect(failed.status.hasPrefix("Failed:"))
        #expect(failed.lastOutputLines.lowercased().contains("unknown instruction"))
    }
}
