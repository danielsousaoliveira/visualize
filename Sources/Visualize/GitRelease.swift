import Foundation

actor GitRelease {
    private let folder: URL
    private let writer: LogFileWriter
    private let report: @Sendable (String) async -> Void

    init(folder: URL, logURL: URL, report: @escaping @Sendable (String) async -> Void) {
        self.folder = folder
        writer = LogFileWriter(url: logURL, limit: Int.max)
        self.report = report
    }

    private func git(_ arguments: [String], allowFailure: Bool = false) async throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = ["-C", folder.path] + arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        let command = "$ git " + arguments.map { String(reflecting: $0) }.joined(separator: " ") + "\n"
        await record(command)
        do { try process.run() }
        catch { await record(error.localizedDescription + "\n"); throw error }
        let drain = PipeDrain(output.fileHandleForReading)
        process.waitUntilExit()
        let result = String(decoding: drain.wait(), as: UTF8.self)
        await record(result + "[exit \(process.terminationStatus)]\n")
        if process.terminationStatus != 0 && !allowFailure {
            throw NSError(domain: "GitRelease", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: result])
        }
        return process.terminationStatus == 0 ? result.trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }

    private func record(_ text: String) async {
        writer.append(Data(text.utf8))
        await report(text)
        if let failure = await writer.flush() {
            await report("Could not save release log: \(failure)\n")
        }
    }

    private func sha(_ ref: String, optional: Bool = false) async throws -> String? {
        let value = try await git(["rev-parse", "--verify", ref + "^{commit}"], allowFailure: optional)
        return value.isEmpty ? nil : value
    }

    func preflight(_ configured: ReleaseSettings) async throws -> ReleasePreflight {
        _ = try await git(["rev-parse", "--git-dir"])
        var settings = configured
        guard !settings.remote.isEmpty, !settings.remote.hasPrefix("-") else { throw invalid("Enter a remote name") }
        _ = try await git(["remote", "get-url", "--", settings.remote])
        _ = try await git(["fetch", "--prune", "--", settings.remote])
        let remoteRefs = "refs/remotes/" + settings.remote + "/"
        if settings.main.isEmpty {
            settings.main = try await sha(remoteRefs + "main", optional: true) != nil ? "main" : "master"
        }
        if settings.production.isEmpty {
            if try await sha(remoteRefs + "production", optional: true) != nil { settings.production = "production" }
            else if try await sha(remoteRefs + "prod", optional: true) != nil { settings.production = "prod" }
            else { settings.production = "production" }
        }
        for branch in [settings.main, settings.production] {
            _ = try await git(["check-ref-format", "refs/heads/" + branch])
            guard !branch.hasPrefix("-") else { throw invalid("Branch names cannot start with a dash") }
        }
        guard settings.main != settings.production else { throw invalid("Main and production must be different branches") }
        let main = try await sha(remoteRefs + settings.main)!
        let production = try await sha(remoteRefs + settings.production, optional: true)
        let incoming = try await subjects(production.map { $0 + ".." + main } ?? main)
        let outgoing: [String]
        if let production { outgoing = try await subjects(main + ".." + production) }
        else { outgoing = [] }
        return ReleasePreflight(settings: settings, mainSHA: main, productionSHA: production, incoming: incoming, outgoing: outgoing)
    }

    private func subjects(_ revision: String) async throws -> [String] {
        let result = try await git(["log", "--format=%h %s", revision, "--"])
        return result.isEmpty ? [] : result.components(separatedBy: "\n")
    }

    func push(_ preflight: ReleasePreflight, confirmation: String) async throws -> String {
        if preflight.unchanged { return "Already up to date" }
        guard !preflight.requiresConfirmation || confirmation == preflight.settings.production else {
            throw invalid("Type the production branch name to confirm")
        }
        let ref = "refs/heads/" + preflight.settings.production
        var arguments = ["push"]
        if preflight.requiresConfirmation {
            arguments.append("--force-with-lease=" + ref + ":" + (preflight.productionSHA ?? ""))
        }
        arguments += ["--", preflight.settings.remote, preflight.mainSHA + ":" + ref]
        _ = try await git(arguments)
        if let local = try await sha(ref, optional: true) {
            do { _ = try await git(["update-ref", ref, preflight.mainSHA, local]) }
            catch { return "Production pushed, but local production could not be updated: " + error.localizedDescription }
        }
        return "Production now matches " + preflight.settings.main
    }

    private func invalid(_ message: String) -> NSError {
        NSError(domain: "GitRelease", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
