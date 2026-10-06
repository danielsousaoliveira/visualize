import Foundation
import Testing
@testable import visualize

struct ScanHelperTests {
    static let nodeGolden = ScanDecoderTests.goldenDirectory.appending(path: "deploy-node.json")
    static let hostileName = "a b'\"$(touch pwned)`touch pwned`\n$HOME"

    @Test func reportsAMissingHelper() async {
        let helper = ScanHelper(executableURL: URL(filePath: "/nonexistent/visualize-scan"))
        await #expect(throws: ScanError.helperMissing) {
            try await helper.scan(folder: URL(filePath: "/tmp"))
        }
    }

    @Test func passesAHostileFolderNameAsOneArgument() async throws {
        let stub = try StubHelper { dir in
            """
            printf '%s' "$#" > '\(dir.path)/argc'
            printf '%s' "$1" > '\(dir.path)/argv1'
            cat '\(Self.nodeGolden.path)'
            """
        }
        defer { stub.remove() }
        let folder = stub.file(Self.hostileName)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let result = try await ScanHelper(executableURL: stub.executable).scan(folder: folder)

        #expect(result.project.name == "hello-node")
        #expect(try String(contentsOf: stub.file("argc"), encoding: .utf8) == "1")
        #expect(try String(contentsOf: stub.file("argv1"), encoding: .utf8) == folder.path(percentEncoded: false))
        for directory in [stub.directory, folder, URL(filePath: FileManager.default.currentDirectoryPath)] {
            #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "pwned").path))
        }
    }

    @Test func stopsAHelperThatRunsPastTheTimeout() async throws {
        let stub = try StubHelper { dir in
            """
            echo $$ > '\(dir.path)/pid'
            exec sleep 30
            """
        }
        defer { stub.remove() }
        let helper = ScanHelper(executableURL: stub.executable, timeout: 1)

        await #expect(throws: ScanError.timedOut(seconds: 1)) {
            try await helper.scan(folder: stub.directory)
        }

        let pidText = try String(contentsOf: stub.file("pid"), encoding: .utf8)
        let pid = try #require(pid_t(pidText.trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(kill(pid, 0) == -1)
    }

    @Test func reportsOutputThatIsNotJSON() async throws {
        let stub = try StubHelper { _ in "echo 'this is not json'" }
        defer { stub.remove() }

        await #expect(throws: ScanError.invalidOutput("missing integer schemaVersion")) {
            try await ScanHelper(executableURL: stub.executable).scan(folder: stub.directory)
        }
    }

    @Test func reportsANonZeroExitWithStderr() async throws {
        let stub = try StubHelper { _ in
            """
            echo 'visualize-scan: Permission denied: /secret' >&2
            exit 1
            """
        }
        defer { stub.remove() }

        do {
            _ = try await ScanHelper(executableURL: stub.executable).scan(folder: stub.directory)
            Issue.record("expected the scan to fail")
        } catch {
            #expect(error as? ScanError == .helperFailed(status: 1, stderr: "visualize-scan: Permission denied: /secret"))
            #expect(error.localizedDescription.contains("Permission denied: /secret"))
        }
    }

    @Test func keepsOnlyTheFirstLinesOfStderr() async throws {
        let stub = try StubHelper { _ in
            """
            for n in 1 2 3 4 5 6 7 8; do echo "line $n" >&2; done
            exit 3
            """
        }
        defer { stub.remove() }

        await #expect(throws: ScanError.helperFailed(status: 3, stderr: "line 1\nline 2\nline 3\nline 4\nline 5")) {
            try await ScanHelper(executableURL: stub.executable).scan(folder: stub.directory)
        }
    }

    @Test func reportsAnUnsupportedSchemaVersion() async throws {
        let stub = try StubHelper { _ in #"echo '{"schemaVersion": 2}'"# }
        defer { stub.remove() }

        await #expect(throws: ScanError.unsupportedVersion(2)) {
            try await ScanHelper(executableURL: stub.executable).scan(folder: stub.directory)
        }
    }

    @Test func readsOutputLargerThanAPipeBuffer() async throws {
        let stub = try StubHelper { _ in
            """
            i=0; while [ $i -lt 2000 ]; do echo 'padding padding padding padding padding' >&2; i=$((i+1)); done
            cat '\(Self.nodeGolden.path)'
            """
        }
        defer { stub.remove() }

        let result = try await ScanHelper(executableURL: stub.executable).scan(folder: stub.directory)
        #expect(result.services.first?.stackId == "node")
    }
}
