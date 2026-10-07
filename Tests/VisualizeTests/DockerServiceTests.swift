import Foundation
import Testing
@testable import visualize

struct DockerServiceTests {
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
        defer {
            let prefix = ["--host", command.endpoint]
            if let remaining = try? CommandOutput.run(command.executable, arguments: prefix + ["ps", "-a", "-q", "--filter", "label=visualize.library=\(project.id.uuidString)"]) {
                let ids = String(decoding: remaining.data, as: UTF8.self).split(whereSeparator: \.isWhitespace).map(String.init)
                if !ids.isEmpty { _ = try? CommandOutput.run(command.executable, arguments: prefix + ["rm", "-f", "-v"] + ids) }
            }
            _ = try? CommandOutput.run(command.executable, arguments: prefix + ["network", "rm", "\(DockerRun.slug(project.name))_default"])
            _ = try? CommandOutput.run(command.executable, arguments: prefix + ["image", "rm", "visualize/\(DockerRun.slug(project.name))-api:dev"])
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
        let dbID = try #require(dbRun.docker?.containerIDs.first)
        let labels = try await command.run(["inspect", "--format", "{{index .Config.Labels \"com.docker.compose.project\"}} {{index .Config.Labels \"visualize.service\"}}", dbID], directory: folder.path)
        #expect(String(decoding: labels, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "\(DockerRun.slug(project.name)) \(db.id)")
        let otherSession = AppState(store: store)
        await otherSession.checkDocker()
        otherSession.setMode(.compose, project: project, service: db)
        await otherSession.startDocker(project: project, service: db)
        let refused = try #require(otherSession.serviceRuns[otherSession.runKey(project: project, service: db)])
        #expect(!refused.active)
        #expect(refused.status.contains("refused"))
        #expect(dbRun.active)
        await state.stop(project: project, service: db)
        #expect(!dbRun.active)
        let stopped = try await command.run(["ps", "--filter", "id=\(dbID)", "--format", "{{.ID}}"], directory: folder.path)
        #expect(stopped.isEmpty)
        await state.restart(project: project, service: db)
        #expect(dbRun.active)
        await state.stop(project: project, service: db)
        await state.stop(project: project, service: api)
        for run in [apiRun, dbRun] {
            for id in run.docker?.containerIDs ?? [] {
                _ = try await command.run(["rm", "-v", id], directory: folder.path)
            }
        }
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
        #expect(String(decoding: port, as: UTF8.self).contains(":49187"))
        await state.restart(project: project, service: dockerService)
        let restarted = try #require(state.serviceRuns[state.runKey(project: project, service: dockerService)])
        #expect(restarted.active)
        #expect(restarted.docker?.containerIDs.first != builtID)
        await state.stop(project: project, service: dockerService)
        #expect(!restarted.active)
        await state.restart(project: project, service: dockerService)
        let afterStop = try #require(state.serviceRuns[state.runKey(project: project, service: dockerService)])
        #expect(afterStop.active)
        await state.stop(project: project, service: dockerService)
        try "INVALID instruction\n".write(to: folder.appending(path: "Dockerfile"), atomically: true, encoding: .utf8)
        await state.startDocker(project: project, service: dockerService)
        let failed = try #require(state.serviceRuns[state.runKey(project: project, service: dockerService)])
        #expect(!failed.active)
        #expect(failed.status.hasPrefix("Failed:"))
        #expect(failed.lastOutputLines.lowercased().contains("unknown instruction"))
        let image = "visualize/\(DockerRun.slug(project.name))-api:dev"
        _ = try await command.run(["image", "rm", image], directory: folder.path)
        for service in [api, db, dockerService] {
            UserDefaults.standard.removeObject(forKey: "serviceMode.\(state.runKey(project: project, service: service))")
        }
    }
}
