import Foundation
import Observation

@MainActor
@Observable
final class ReleaseOperation {
    var output = ""
    var result: String?
    var preflight: ReleasePreflight?
    var busy = false
    let folder: URL
    let logURL: URL
    @ObservationIgnored private lazy var git = GitRelease(folder: folder, logURL: logURL) { [weak self] text in
        await self?.append(text)
    }

    init(folder: URL, logURL: URL) {
        self.folder = folder
        self.logURL = logURL
        output = GitOutputRedactor.redact((try? String(contentsOf: logURL, encoding: .utf8)) ?? "")
    }

    private func append(_ text: String) { output += text }

    func prepare(_ settings: ReleaseSettings) async {
        guard !busy else { return }
        busy = true
        preflight = nil
        result = nil
        defer { busy = false }
        do {
            preflight = try await git.preflight(settings)
            if preflight?.unchanged == true { result = "Already up to date" }
        } catch { result = GitOutputRedactor.redact(error.localizedDescription) }
    }

    func push(confirmation: String) async {
        guard !busy, let reviewed = preflight else { return }
        busy = true
        preflight = nil
        defer { busy = false }
        do { result = try await git.push(reviewed, confirmation: confirmation) }
        catch { result = GitOutputRedactor.redact(error.localizedDescription) }
    }
}
