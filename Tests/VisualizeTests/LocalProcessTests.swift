import Foundation
import Testing
import Darwin
@testable import visualize

struct LocalProcessTests {
    private var drainerURL: URL {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let candidates = [".build/out/Products/Debug/visualize", ".build/debug/visualize"].map { root.appending(path: $0) }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }!
    }

    @Test func preservesArgumentsDirectoryAndProcessGroup() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "$(touch pwned)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let recipe = RunRecipe(argv: ["/bin/sleep", "10"], workingDirectory: folder.path, addedEnvironmentKeys: [], startedAt: Date())
        let (pid, output) = try LocalProcess.start(recipe, environment: ["PATH": "/bin"], outputDrainerURL: drainerURL)
        defer { kill(-pid, SIGKILL); var status: Int32 = 0; waitpid(pid, &status, 0); try? output.close() }
        #expect(getpgid(pid) == pid)
        #expect(getpgid(pid) != getpgrp())
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "pwned").path))
    }

    @Test func resolvesCapturedPathAndCapturesExitOutput() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let tool = folder.appending(path: "custom-tool")
        try Data("#!/bin/sh\nprintf '%s' \"$1\"\nprintf 'error' >&2\nexit 1\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tool.path)
        let recipe = RunRecipe(argv: ["custom-tool", "$(touch pwned)"], workingDirectory: folder.path, addedEnvironmentKeys: [], startedAt: Date())
        let (pid, output) = try LocalProcess.start(recipe, environment: ["PATH": folder.path], outputDrainerURL: drainerURL)
        defer { try? output.close() }
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        #expect((status >> 8) & 0xff == 1)
        #expect(String(decoding: output.readDataToEndOfFile(), as: UTF8.self) == "$(touch pwned)error")
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "pwned").path))
    }

    @Test @MainActor func noisyOutputRetainsOnlyLatestMiB() throws {
        let recipe = RunRecipe(argv: ["/bin/sh", "-c", "/bin/dd if=/dev/zero bs=65536 count=64 2>/dev/null; printf latest"], workingDirectory: "/tmp", addedEnvironmentKeys: [], startedAt: Date())
        let (pid, output) = try LocalProcess.start(recipe, environment: ["PATH": "/bin"], outputDrainerURL: drainerURL)
        defer { try? output.close() }
        let run = ServiceRun(recipe: recipe)
        var total = 0
        while let data = try output.read(upToCount: 65_536), !data.isEmpty {
            total += data.count
            run.append(data)
            #expect(run.output.count <= 1_048_576)
        }
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        #expect(total == 4_194_310)
        #expect(run.output.count == 1_048_576)
        #expect(String(decoding: run.output.suffix(6), as: UTF8.self) == "latest")
    }

    @Test @MainActor func streamsBothChannelsBeforeServiceExit() async throws {
        let recipe = RunRecipe(argv: ["/bin/sh", "-c", "printf '\\033[32mready\\033[0m\\n'; printf 'error\\n' >&2; sleep 2"], workingDirectory: "/tmp", addedEnvironmentKeys: [], startedAt: Date())
        let errors = Pipe()
        let (pid, output) = try LocalProcess.start(recipe, environment: ["PATH": "/bin"], outputDrainerURL: drainerURL, stderr: errors)
        defer { kill(-pid, SIGKILL); var status: Int32 = 0; waitpid(pid, &status, 0); try? output.close(); try? errors.fileHandleForReading.close() }
        let started = ContinuousClock.now
        async let stdout = LocalProcess.readOutput(output)
        async let stderr = LocalProcess.readOutput(errors.fileHandleForReading)
        let captured = try await (stdout, stderr)
        #expect(started.duration(to: .now) < .seconds(1))
        #expect(kill(pid, 0) == 0)
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = ServiceLog(fileURL: folder.appending(path: "service.log"))
        log.append(try #require(captured.0))
        log.append(try #require(captured.1), isError: true)
        #expect(log.lines.contains { $0.text == "ready" && !$0.isError })
        #expect(log.lines.contains { $0.text == "error" && $0.isError })
        #expect(await log.writer.flush() == nil)
    }

    @Test func disconnectedCaptureKeepsNoisyServiceRunning() async throws {
        let recipe = RunRecipe(argv: ["/bin/sh", "-c", "/bin/dd if=/dev/zero bs=65536 count=64 2>/dev/null; exit 0"], workingDirectory: "/tmp", addedEnvironmentKeys: [], startedAt: Date())
        let (pid, output) = try LocalProcess.start(recipe, environment: ["PATH": "/bin"], outputDrainerURL: drainerURL)
        try output.close()
        var status: Int32 = 0
        var exited: Int32 = 0
        let deadline = Date().addingTimeInterval(5)
        while exited == 0 && Date() < deadline {
            exited = waitpid(pid, &status, WNOHANG)
            try await Task.sleep(for: .milliseconds(20))
        }
        if exited == 0 { kill(-pid, SIGKILL); waitpid(pid, &status, 0) }
        #expect(exited == pid)
        #expect(status == 0)
    }

    @Test func listeningRequiresMatchingProcessGroup() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        #expect(descriptor >= 0)
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        #expect(bound == 0)
        #expect(listen(descriptor, 1) == 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let inspected = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        #expect(inspected == 0)
        let port = Int(UInt16(bigEndian: address.sin_port))
        #expect(LocalProcess.listening(port: port, processGroup: getpgrp()))
        #expect(!LocalProcess.listening(port: port, processGroup: Int32.max))
    }

    @Test func approvalChangesWithCommandOrDirectory() {
        let first = RunRecipe(argv: ["pnpm", "run", "dev"], workingDirectory: "/project", addedEnvironmentKeys: [], startedAt: Date())
        let changed = RunRecipe(argv: ["pnpm", "run", "start"], workingDirectory: "/project", addedEnvironmentKeys: [], startedAt: Date())
        #expect(first.approvalKey != changed.approvalKey)
    }
}
