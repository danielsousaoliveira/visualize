import Foundation
import Testing
import AppKit
import SwiftUI
@testable import visualize

struct ServiceLogTests {
    @Test func stripsSplitANSIAndPreservesSplitUTF8() {
        var decoder = LogStreamDecoder()
        #expect(decoder.decode(Data([27, 91, 51])) == "")
        #expect(decoder.decode(Data("2mhello\u{1b}[0m\u{1b}]0;title".utf8)) == "hello")
        #expect(decoder.decode(Data([27])) == "")
        #expect(decoder.decode(Data([92, 0xf0, 0x9f])) == "")
        #expect(decoder.decode(Data([0x98, 0x80, 10])) == "😀\n")
    }

    @Test @MainActor func retainsLinesAndClearsOnlyTheView() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "service.log")
        let log = ServiceLog(fileURL: url)
        log.append(Data((0..<5005).map { "line \($0)\n" }.joined().utf8))
        #expect(log.lines.count == 5000)
        #expect(log.lines.first?.text == "line 5")
        log.append(Data("\u{1b}[31merr".utf8), isError: true)
        log.append(Data("or\u{1b}[0m".utf8), isError: true)
        #expect(log.lines.last?.text == "error")
        #expect(log.lines.last?.isError == true)
        log.finish(isError: true)
        #expect(log.text.hasSuffix("error"))
        #expect(await log.writer.flush() == nil)
        let saved = try Data(contentsOf: url)
        #expect(!saved.contains(27))
        log.clear()
        #expect(log.lines.isEmpty)
        #expect(try Data(contentsOf: url) == saved)
        log.append(Data("new\n".utf8))
        #expect(log.text == "new")
    }

    @Test func capsDiskAtFourTenMegabyteFiles() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "service.log")
        let writer = LogFileWriter(url: url)
        for value in 0..<5 { writer.append(Data(repeating: UInt8(65 + value), count: 10_000_001)) }
        #expect(await writer.flush() == nil)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])
        #expect(files.count == 4)
        for file in files { #expect(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize! <= 10_000_000) }
        #expect(try Data(contentsOf: url).last == 69)
        #expect(try Data(contentsOf: URL(filePath: url.path + ".3")).first == 66)
    }

    @Test func refusesSymlinkedLogAndRotationFiles() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appending(path: "target")
        try Data("keep".utf8).write(to: target)
        let active = folder.appending(path: "service.log")
        try FileManager.default.createSymbolicLink(at: active, withDestinationURL: target)
        let writer = LogFileWriter(url: active, limit: 4)
        writer.append(Data("unsafe".utf8))
        #expect(await writer.flush() != nil)
        #expect(try String(contentsOf: target, encoding: .utf8) == "keep")

        try FileManager.default.removeItem(at: active)
        try Data("full".utf8).write(to: active)
        let rotatedTarget = folder.appending(path: "rotated-target")
        try Data("untouched".utf8).write(to: rotatedTarget)
        try FileManager.default.createSymbolicLink(atPath: active.path + ".3", withDestinationPath: rotatedTarget.path)
        let rotatingWriter = LogFileWriter(url: active, limit: 4)
        rotatingWriter.append(Data("trigger".utf8))
        #expect(await rotatingWriter.flush() != nil)
        #expect(try String(contentsOf: rotatedTarget, encoding: .utf8) == "untouched")
    }

    @Test @MainActor func reportsOutputReadFailures() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = ServiceLog(fileURL: folder.appending(path: "failure.log"))
        let failure = OrderedOutputReader.readResult(-1, error: EBADF, isError: false)
        #expect(failure.data == nil)
        #expect(failure.failure != nil)
        if let message = failure.failure { log.reportReadFailure(message, isError: failure.isError) }
        #expect(log.error?.contains("Could not read stdout output") == true)
        #expect(OrderedOutputReader.readResult(0, isError: false).failure == nil)
    }

    @Test @MainActor func followerStreamsBothChannelsAndStopsOnClose() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let executable = folder.appending(path: "docker-stub")
        try Data("#!/bin/sh\nprintf '%s\\n' \"$@\" > arguments\necho $$ > pid\nprintf 'Postgres startup\\n'\nprintf '\\033[31merror\\033[0m\\n' >&2\nexec /bin/sleep 30\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let docker = DockerRun(command: DockerCommand(executable: executable.path, endpoint: "unix:///tmp/docker.sock"), mode: .compose, projectID: UUID(), projectSlug: "test", serviceName: "db", composeArguments: [], containerIDs: ["container-id"])
        let log = ServiceLog(fileURL: folder.appending(path: "db.log"))
        let follower = DockerLogFollower()
        follower.start(docker, directory: folder.path, log: log)
        defer { follower.stop() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while log.lines.count < 2 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(log.lines.contains { $0.text == "Postgres startup" && !$0.isError })
        #expect(log.lines.contains { $0.text == "error" && $0.isError })
        let arguments = try String(contentsOf: folder.appending(path: "arguments"), encoding: .utf8)
        #expect(arguments == "--host\nunix:///tmp/docker.sock\nlogs\n-f\n--tail\n500\ncontainer-id\n")
        let pid = Int32(try String(contentsOf: folder.appending(path: "pid"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
        await follower.stop().value
        let stopped = ContinuousClock.now.advanced(by: .seconds(2))
        while kill(pid, 0) == 0 && ContinuousClock.now < stopped { try await Task.sleep(for: .milliseconds(20)) }
        #expect(kill(pid, 0) == -1)
        #expect(log.lines.count == 2)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VISUALIZE_DOCKER_TESTS"] == "1"))
    @MainActor func followsRealComposePostgresAndEndsFollower() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "visualize-log-compose-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try """
        services:
          db:
            image: postgres:17-alpine
            environment:
              POSTGRES_HOST_AUTH_METHOD: trust
        """.write(to: folder.appending(path: "compose.yaml"), atomically: true, encoding: .utf8)
        let command = try DockerCommand.connect(overridePath: nil)
        let base = ["compose", "-p", "log-test-\(UUID().uuidString.lowercased())", "-f", folder.appending(path: "compose.yaml").path]
        do {
            _ = try await command.run(base + ["up", "-d", "--pull", "never", "db"], directory: folder.path)
            let output = try await command.run(base + ["ps", "-q", "db"], directory: folder.path)
            let id = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(!id.isEmpty)
            let log = ServiceLog(fileURL: folder.appending(path: "db.log"))
            let follower = DockerLogFollower()
            defer { follower.stop() }
            follower.start(DockerRun(command: command, mode: .compose, projectID: UUID(), projectSlug: "test", serviceName: "db", composeArguments: base, containerIDs: [id]), directory: folder.path, log: log)
            let deadline = ContinuousClock.now.advanced(by: .seconds(20))
            while !log.text.contains("ready to accept connections") && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
            #expect(log.text.contains("ready to accept connections"))
            let pattern = "logs -f --tail 500 " + id
            #expect(try CommandOutput.run("/usr/bin/pgrep", arguments: ["-f", pattern]).status == 0)
            await follower.stop().value
            #expect(try CommandOutput.run("/usr/bin/pgrep", arguments: ["-f", pattern]).status == 1)
            #expect(await log.writer.flush() == nil)
            #expect(try String(contentsOf: log.writer.url, encoding: .utf8).contains("ready to accept connections"))
        } catch {
            _ = try? await command.run(base + ["down", "-v"], directory: folder.path)
            throw error
        }
        _ = try await command.run(base + ["down", "-v"], directory: folder.path)
    }

    @Test @MainActor func highlightsSearchStepsAndPausesTail() async throws {
        var following = true
        let binding = Binding(get: { following }, set: { following = $0 })
        let lines = (0..<100).map { LogLine(id: $0, text: $0 % 10 == 0 ? "error \($0)" : "request \($0)", isError: $0 == 90) }
        var view = LogTextView(lines: lines, revision: 1, search: "error", match: 0, jump: 0, following: binding)
        let coordinator = view.makeCoordinator()
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 2000))
        scroll.documentView = text
        view.render(scroll, coordinator: coordinator)
        #expect(coordinator.matches.count == 10)
        #expect(text.selectedRange() == coordinator.matches[0])
        for range in coordinator.matches { #expect(text.textStorage?.attribute(.backgroundColor, at: range.location, effectiveRange: nil) != nil) }
        view = LogTextView(lines: lines, revision: 1, search: "error", match: 1, jump: 0, following: binding)
        view.render(scroll, coordinator: coordinator)
        #expect(text.selectedRange() == coordinator.matches[1])
        view = LogTextView(lines: lines, revision: 1, search: "error", match: -1, jump: 0, following: binding)
        view.render(scroll, coordinator: coordinator)
        #expect(text.selectedRange() == coordinator.matches[9])
        scroll.contentView.scroll(to: .zero)
        coordinator.scrolled(scroll)
        await Task.yield()
        #expect(!following)
        following = true
        view = LogTextView(lines: lines, revision: 1, search: "error", match: -1, jump: 1, following: binding)
        view.render(scroll, coordinator: coordinator)
        #expect(following)
        #expect(scroll.contentView.bounds.maxY >= text.bounds.maxY - 8)
    }

    @Test @MainActor func localExitKeepsOutputAndLogFile() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "visualize-log-exit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var result = try ScanDecoder.decode(Data(contentsOf: ScanDecoderTests.goldenDirectory.appending(path: "scan-compose-env.json")))
        var service = try #require(result.services.first)
        service.port = nil
        result.services = [service]
        let project = Project(folder: folder, lastResult: result)
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let drainer = try #require([".build/out/Products/Debug/visualize", ".build/debug/visualize"].map { root.appending(path: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) })
        let state = AppState(store: ProjectLibraryStore(directory: folder.appending(path: "library")), outputDrainerURL: drainer)
        let recipe = RunRecipe(argv: ["/bin/sh", "-c", "printf 'final stdout\\n'; printf 'final stderr\\n' >&2"], workingDirectory: folder.path, addedEnvironmentKeys: [], startedAt: Date())
        await state.start(project: project, service: service, recipe: recipe, storedEnvironment: ["PATH": "/bin"])
        let run = try #require(state.serviceRuns[state.runKey(project: project, service: service)])
        let log = state.logs(project: project, service: service)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while (run.active || log.lines.count < 2) && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!run.active)
        #expect(log.lines.contains { $0.text == "final stdout" && !$0.isError })
        #expect(log.lines.contains { $0.text == "final stderr" && $0.isError })
        #expect(await log.writer.flush() == nil)
        let saved = try String(contentsOf: log.writer.url, encoding: .utf8)
        #expect(saved.contains("final stdout"))
        #expect(saved.contains("final stderr"))
        #expect(log.writer.url.path.hasPrefix(folder.path))
    }

    @Test @MainActor func interleavedPartialLinesKeepObservedOrder() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = ServiceLog(fileURL: folder.appending(path: "ordered.log"))
        log.append(Data("first".utf8))
        log.append(Data("second\n".utf8), isError: true)
        log.append(Data("third\n".utf8))
        #expect(log.lines.map(\.text) == ["first", "second", "third"])
        #expect(log.lines.map(\.isError) == [false, true, false])
        #expect(await log.writer.flush() == nil)
        #expect(try String(contentsOf: log.writer.url, encoding: .utf8) == "[stdout] first\n[stderr] second\n[stdout] third\n")
    }

    @Test @MainActor func reopenWaitsForTermIgnoringFollower() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let executable = folder.appending(path: "docker-stub")
        try Data("#!/usr/bin/perl\n$SIG{TERM} = 'IGNORE'; $| = 1; open my $p, '>>', 'pids' or die $!; print $p qq($$\\n); close $p; print qq(ready\\n); sleep 30;\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let docker = DockerRun(command: DockerCommand(executable: executable.path, endpoint: "unix:///tmp/docker.sock"), mode: .compose, projectID: UUID(), projectSlug: "test", serviceName: "db", composeArguments: [], containerIDs: ["test-id"])
        let log = ServiceLog(fileURL: folder.appending(path: "db.log"))
        let follower = DockerLogFollower()
        defer { follower.stop() }
        follower.start(docker, directory: folder.path, log: log)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while log.lines.isEmpty && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let first = Int32(try String(contentsOf: folder.appending(path: "pids"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
        let cleanup = follower.stop()
        follower.start(docker, directory: folder.path, log: log)
        await cleanup.value
        #expect(kill(first, 0) == -1)
        let reopened = ContinuousClock.now.advanced(by: .seconds(2))
        var pids: [Int32] = []
        repeat {
            pids = (try String(contentsOf: folder.appending(path: "pids"), encoding: .utf8)).split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
            if pids.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        } while pids.count < 2 && ContinuousClock.now < reopened
        #expect(pids.count == 2)
        #expect(kill(first, 0) == -1)
        await follower.stop().value
        for pid in pids { #expect(kill(pid, 0) == -1) }
    }

    @Test @MainActor func readyStreamsUseStdoutThenStderrTieBreak() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = ServiceLog(fileURL: folder.appending(path: "ordered.log"))
        let output = Pipe()
        let errors = Pipe()
        try output.fileHandleForWriting.write(contentsOf: Data("first\n".utf8))
        try errors.fileHandleForWriting.write(contentsOf: Data("second\n".utf8))
        try output.fileHandleForWriting.close()
        try errors.fileHandleForWriting.close()
        await OrderedOutputReader.drain(stdout: output.fileHandleForReading, stderr: errors.fileHandleForReading) { data, isError in
            if let data { log.append(data, isError: isError) }
            else { log.finish(isError: isError) }
        }
        #expect(log.lines.map(\.text) == ["first", "second"])
        #expect(log.lines.map(\.isError) == [false, true])
        #expect(await log.writer.flush() == nil)
        #expect(try String(contentsOf: log.writer.url, encoding: .utf8) == "[stdout] first\n[stderr] second\n")
    }

}
