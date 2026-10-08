import Foundation
import Testing
@testable import visualize

struct GitReleaseTests {
    private struct Repository {
        let root: URL
        let local: URL
        let remote: URL
        let log: URL

        init(production: String? = "production", main: String = "main") throws {
            root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            local = root.appending(path: "local")
            remote = root.appending(path: "remote.git")
            log = root.appending(path: "release.log")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            _ = try Self.run(["init", "--bare", remote.path])
            _ = try Self.run(["init", "-b", main, local.path])
            _ = try git(["config", "user.name", "Test"])
            _ = try git(["config", "user.email", "test@example.com"])
            _ = try git(["commit", "--allow-empty", "-m", "Base"])
            _ = try git(["remote", "add", "origin", remote.path])
            _ = try git(["push", "origin", main])
            if let production {
                _ = try git(["branch", production])
                _ = try git(["push", "origin", production])
            }
        }

        func git(_ args: [String]) throws -> String { try Self.run(["-C", local.path] + args) }
        func remoteSHA(_ branch: String) throws -> String { try Self.run(["--git-dir", remote.path, "rev-parse", "refs/heads/" + branch]) }
        func release() -> GitRelease { GitRelease(folder: local, logURL: log) { _ in } }
        func remove() { try? FileManager.default.removeItem(at: root) }

        static func run(_ args: [String]) throws -> String {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(filePath: "/usr/bin/git")
            process.arguments = args
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            try process.run()
            let drain = PipeDrain(pipe.fileHandleForReading)
            process.waitUntilExit()
            let text = String(decoding: drain.wait(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard process.terminationStatus == 0 else { throw NSError(domain: "TestGit", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
            return text
        }
    }

    @Test func fastForwardListsSubjectsAndPreservesDirtyTree() async throws {
        let repo = try Repository()
        defer { repo.remove() }
        for index in 1...3 { _ = try repo.git(["commit", "--allow-empty", "-m", "Change \(index)"]) }
        _ = try repo.git(["push", "origin", "main"])
        let dirty = repo.local.appending(path: "dirty.txt")
        try "keep me".write(to: dirty, atomically: true, encoding: .utf8)
        let before = try repo.git(["status", "--porcelain"])
        let git = repo.release()
        let review = try await git.preflight(ReleaseSettings())
        #expect(review.incoming.count == 3)
        #expect(review.incoming.contains { $0.contains("Change 1") })
        #expect(review.outgoing.isEmpty)
        _ = try await git.push(review, confirmation: "")
        #expect(try repo.remoteSHA("production") == repo.remoteSHA("main"))
        #expect(try repo.git(["rev-parse", "production"]) == review.mainSHA)
        #expect(try repo.git(["branch", "--show-current"]) == "main")
        #expect(try repo.git(["status", "--porcelain"]) == before)
        #expect(try String(contentsOf: dirty, encoding: .utf8) == "keep me")
        let log = try String(contentsOf: repo.log, encoding: .utf8)
        #expect(log.contains("Change 1"))
        #expect(log.contains("\"push\""))
        #expect(!log.contains("--force"))
    }

    @Test func divergenceRequiresExactConfirmationAndPinsLease() async throws {
        let repo = try Repository()
        defer { repo.remove() }
        _ = try repo.git(["checkout", "production"])
        _ = try repo.git(["commit", "--allow-empty", "-m", "Hotfix"])
        _ = try repo.git(["push", "origin", "production"])
        _ = try repo.git(["checkout", "main"])
        let git = repo.release()
        let review = try await git.preflight(ReleaseSettings())
        #expect(review.outgoing.count == 1)
        #expect(review.outgoing[0].contains("Hotfix"))
        await #expect(throws: (any Error).self) { try await git.push(review, confirmation: "wrong") }
        _ = try await git.push(review, confirmation: "production")
        #expect(try repo.remoteSHA("production") == review.mainSHA)
        #expect(try String(contentsOf: repo.log, encoding: .utf8).contains("--force-with-lease=refs/heads/production:" + review.productionSHA!))
    }

    @Test func concurrentPushRejectsStaleLease() async throws {
        let repo = try Repository()
        defer { repo.remove() }
        _ = try repo.git(["checkout", "production"])
        _ = try repo.git(["commit", "--allow-empty", "-m", "Hotfix"])
        _ = try repo.git(["push", "origin", "production"])
        let git = repo.release()
        let review = try await git.preflight(ReleaseSettings())
        _ = try repo.git(["commit", "--allow-empty", "-m", "Concurrent hotfix"])
        _ = try repo.git(["push", "origin", "production"])
        let concurrent = try repo.remoteSHA("production")
        await #expect(throws: (any Error).self) { try await git.push(review, confirmation: "production") }
        #expect(try repo.remoteSHA("production") == concurrent)
        #expect(try String(contentsOf: repo.log, encoding: .utf8).contains("stale info"))
    }

    @Test func equalBranchesNeverPush() async throws {
        let repo = try Repository()
        defer { repo.remove() }
        let git = repo.release()
        let review = try await git.preflight(ReleaseSettings())
        #expect(review.unchanged)
        #expect(try await git.push(review, confirmation: "") == "Already up to date")
        #expect(try !String(contentsOf: repo.log, encoding: .utf8).contains("\"push\""))
    }

    @Test func missingProductionNeedsConfirmationAndMasterIsDetected() async throws {
        let repo = try Repository(production: nil, main: "master")
        defer { repo.remove() }
        let git = repo.release()
        let review = try await git.preflight(ReleaseSettings())
        #expect(review.settings.main == "master")
        #expect(review.productionSHA == nil)
        #expect(review.requiresConfirmation)
        await #expect(throws: (any Error).self) { try await git.push(review, confirmation: "") }
        let refs = try Repository.run(["--git-dir", repo.remote.path, "for-each-ref", "refs/heads/production"])
        #expect(refs.isEmpty)
        _ = try await git.push(review, confirmation: "production")
        #expect(try repo.remoteSHA("production") == review.mainSHA)
    }

    @Test func shellMetacharactersStayLiteral() async throws {
        let branch = "feat;touch-pwned"
        let repo = try Repository(production: branch)
        defer { repo.remove() }
        _ = try repo.git(["commit", "--allow-empty", "-m", "Change"])
        _ = try repo.git(["push", "origin", "main"])
        let git = repo.release()
        let review = try await git.preflight(ReleaseSettings(main: "main", production: branch))
        _ = try await git.push(review, confirmation: "")
        #expect(try repo.remoteSHA(branch) == review.mainSHA)
        #expect(!FileManager.default.fileExists(atPath: repo.local.appending(path: "pwned").path))
    }

    @Test func checkedOutProductionKeepsRefStatusIndexAndFiles() async throws {
        let repo = try Repository()
        defer { repo.remove() }
        let file = repo.local.appending(path: "tracked.txt")
        try "base".write(to: file, atomically: true, encoding: .utf8)
        _ = try repo.git(["add", "tracked.txt"])
        _ = try repo.git(["commit", "-m", "Track file"])
        _ = try repo.git(["branch", "-f", "production"])
        _ = try repo.git(["push", "origin", "main", "production"])
        try "remote change".write(to: file, atomically: true, encoding: .utf8)
        _ = try repo.git(["commit", "-am", "Update file"])
        _ = try repo.git(["push", "origin", "main"])
        _ = try repo.git(["checkout", "production"])
        try "staged work".write(to: file, atomically: true, encoding: .utf8)
        _ = try repo.git(["add", "tracked.txt"])
        try "unstaged work".write(to: file, atomically: true, encoding: .utf8)
        let index = try repo.git(["ls-files", "--stage"])
        let original = try repo.git(["rev-parse", "production"])
        let status = try repo.git(["status", "--porcelain"])
        let git = repo.release()
        let review = try await git.preflight(ReleaseSettings())
        let result = try await git.push(review, confirmation: "")
        #expect(try repo.git(["rev-parse", "production"]) == original)
        #expect(try repo.remoteSHA("production") == review.mainSHA)
        #expect(try repo.git(["status", "--porcelain"]) == status)
        #expect(result.contains("left unchanged"))
        #expect(try repo.git(["branch", "--show-current"]) == "production")
        #expect(try repo.git(["ls-files", "--stage"]) == index)
        #expect(try String(contentsOf: file, encoding: .utf8) == "unstaged work")
    }

    @Test func creationLeaseRejectsBranchCreatedAfterReview() async throws {
        let repo = try Repository(production: nil)
        defer { repo.remove() }
        let git = repo.release()
        let review = try await git.preflight(ReleaseSettings())
        _ = try repo.git(["commit", "--allow-empty", "-m", "Concurrent release"])
        _ = try repo.git(["push", "origin", "HEAD:refs/heads/production"])
        let concurrent = try repo.remoteSHA("production")
        await #expect(throws: (any Error).self) { try await git.push(review, confirmation: "production") }
        #expect(try repo.remoteSHA("production") == concurrent)
    }

    @Test func invalidBranchWithSpaceIsRejectedWithoutShellExecution() async throws {
        let repo = try Repository()
        defer { repo.remove() }
        let git = repo.release()
        await #expect(throws: (any Error).self) {
            try await git.preflight(ReleaseSettings(main: "main", production: "feat;touch pwned"))
        }
        #expect(!FileManager.default.fileExists(atPath: repo.local.appending(path: "pwned").path))
    }

    @Test func gitErrorsAreRetainedInTheProjectLog() async throws {
        let repo = try Repository()
        defer { repo.remove() }
        let git = repo.release()
        await #expect(throws: (any Error).self) {
            try await git.preflight(ReleaseSettings(remote: "missing"))
        }
        #expect(try String(contentsOf: repo.log, encoding: .utf8).contains("No such remote"))
        _ = try repo.git(["remote", "set-url", "origin", repo.root.appending(path: "missing.git").path])
        await #expect(throws: (any Error).self) { try await git.preflight(ReleaseSettings()) }
        #expect(try String(contentsOf: repo.log, encoding: .utf8).contains("does not appear to be a git repository"))
        let nonGit = GitRelease(folder: repo.root, logURL: repo.log) { _ in }
        await #expect(throws: (any Error).self) { try await nonGit.preflight(ReleaseSettings()) }
        #expect(try String(contentsOf: repo.log, encoding: .utf8).contains("not a git repository"))
    }

    @Test func productionCheckedOutInLinkedWorktreeIsPreserved() async throws {
        let repo = try Repository()
        defer { repo.remove() }
        let worktree = repo.root.appending(path: "production-worktree")
        _ = try repo.git(["worktree", "add", worktree.path, "production"])
        let original = try repo.git(["rev-parse", "production"])
        _ = try repo.git(["commit", "--allow-empty", "-m", "Main change"])
        _ = try repo.git(["push", "origin", "main"])
        let git = repo.release()
        let review = try await git.preflight(ReleaseSettings())
        let result = try await git.push(review, confirmation: "")
        #expect(try repo.remoteSHA("production") == review.mainSHA)
        #expect(try repo.git(["rev-parse", "production"]) == original)
        #expect(try Repository.run(["-C", worktree.path, "status", "--porcelain"]).isEmpty)
        #expect(result.contains("left unchanged"))
    }

    @Test func credentialsAreRemovedFromGitFailuresAndLogs() async throws {
        let repo = try Repository()
        defer { repo.remove() }
        let url = "file://release-user:release-secret@" + repo.root.appending(path: "missing.git").path + "?access_token=release-token"
        _ = try repo.git(["remote", "set-url", "origin", url])
        let git = repo.release()
        do {
            _ = try await git.preflight(ReleaseSettings())
            Issue.record("Expected fetch to fail")
        } catch {
            for secret in ["release-user", "release-secret", "release-token"] {
                #expect(!error.localizedDescription.contains(secret))
            }
        }
        let log = try String(contentsOf: repo.log, encoding: .utf8)
        for secret in ["release-user", "release-secret", "release-token"] {
            #expect(!log.contains(secret))
        }
        #expect(log.contains("[output omitted]"))
        #expect(log.contains("[redacted]"))
    }

    @Test func redactsUserInfoAndSignedURLParameters() {
        let text = "fatal: https://token-only@example.com/repo and ssh://user:password@example.com/repo?token=secret#fragment"
        let redacted = GitOutputRedactor.redact(text)
        for secret in ["token-only", "user", "password", "secret", "fragment"] {
            #expect(!redacted.contains(secret))
        }
        #expect(redacted.contains("example.com/repo"))
        #expect(GitOutputRedactor.redact("abc123 Fix startup\n[exit 0]") == "abc123 Fix startup\n[exit 0]")
    }

    @Test func releaseSettingsSurviveLibraryRoundTrip() throws {
        let repo = try Repository()
        defer { repo.remove() }
        var project = Project(folder: repo.local)
        project.releaseSettings = ReleaseSettings(main: "master", production: "prod", remote: "deploy")
        let store = ProjectLibraryStore(directory: repo.root.appending(path: "library"))
        try store.save([project])
        #expect(try store.load().first?.releaseSettings == project.releaseSettings)
        project.releaseSettings = nil
        try store.save([project])
        #expect(try store.load().first?.releaseSettings == nil)
    }
}
