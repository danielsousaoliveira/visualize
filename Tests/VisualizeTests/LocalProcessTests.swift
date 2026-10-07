import Foundation
import Testing
import Darwin
@testable import visualize

struct LocalProcessTests {
    @Test func preservesArgumentsDirectoryAndProcessGroup() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "$(touch pwned)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let recipe = RunRecipe(argv: ["/bin/sleep", "10"], workingDirectory: folder.path, addedEnvironmentKeys: [], startedAt: Date())
        let (pid, output) = try LocalProcess.start(recipe, environment: ["PATH": "/bin"])
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
        let (pid, output) = try LocalProcess.start(recipe, environment: ["PATH": folder.path])
        defer { try? output.close() }
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        #expect((status >> 8) & 0xff == 1)
        #expect(String(decoding: output.availableData, as: UTF8.self) == "$(touch pwned)error")
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "pwned").path))
    }

    @Test func approvalChangesWithCommandOrDirectory() {
        let first = RunRecipe(argv: ["pnpm", "run", "dev"], workingDirectory: "/project", addedEnvironmentKeys: [], startedAt: Date())
        let changed = RunRecipe(argv: ["pnpm", "run", "start"], workingDirectory: "/project", addedEnvironmentKeys: [], startedAt: Date())
        #expect(first.approvalKey != changed.approvalKey)
    }
}
