import Darwin
import Foundation
import Testing
@testable import visualize

struct OwnedProcessGroupTests {
    private func launch(_ argv: [String]) throws -> (Int32, FileHandle) {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let drainer = [".build/out/Products/Debug/visualize", ".build/debug/visualize"].map { root.appending(path: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }!
        let recipe = RunRecipe(argv: argv, workingDirectory: "/tmp", addedEnvironmentKeys: [], startedAt: Date())
        return try LocalProcess.start(recipe, environment: ["PATH": "/usr/bin:/bin"], outputDrainerURL: drainer)
    }

    @Test func mismatchedIdentitySendsNoSignal() async throws {
        let (pid, output) = try launch(["/bin/sleep", "30"])
        defer { kill(-pid, SIGKILL); var status: Int32 = 0; waitpid(pid, &status, 0); try? output.close() }
        let group = try #require(OwnedProcessGroup.capture(pid))
        let wrong = OwnedProcessGroup(pid: pid, seconds: group.seconds + 1, microseconds: group.microseconds)
        #expect(await wrong.stop() == false)
        #expect(group.exists)
        #expect(!wrong.signal(SIGKILL))
        #expect(OwnedProcessGroup.capture(1) == nil)
        #expect(OwnedProcessGroup.capture(getpgrp()) == nil)
    }

    @Test func killsTermIgnoringGroupAfterFiveSeconds() async throws {
        let (pid, output) = try launch(["/usr/bin/perl", "-e", "$SIG{TERM} = 'IGNORE'; $| = 1; print qq(ready\\n); sleep 30;"])
        defer { kill(-pid, SIGKILL); var status: Int32 = 0; waitpid(pid, &status, 0); try? output.close() }
        _ = try output.read(upToCount: 6)
        let group = try #require(OwnedProcessGroup.capture(pid))
        let clock = ContinuousClock()
        let started = clock.now
        #expect(await group.stop())
        #expect(started.duration(to: clock.now) >= .seconds(5))
        #expect(started.duration(to: clock.now) < .seconds(8))
        #expect(!group.exists)
    }

    @Test func stopsChildrenWhenLeaderExitsOnTerm() async throws {
        let (pid, output) = try launch(["/usr/bin/perl", "-e", "my $child = fork(); if ($child == 0) { $SIG{TERM} = 'IGNORE'; $| = 1; print qq(ready\\n); sleep 30; exit; } sleep 30;"])
        defer { kill(-pid, SIGKILL); var status: Int32 = 0; waitpid(pid, &status, 0); try? output.close() }
        _ = try output.read(upToCount: 6)
        let group = try #require(OwnedProcessGroup.capture(pid))
        #expect(await group.stop())
        #expect(!group.exists)
    }
}
