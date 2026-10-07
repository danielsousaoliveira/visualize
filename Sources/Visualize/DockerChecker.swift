import Foundation

struct DockerChecker: Sendable {
    var searchPaths: [String] = [
        "/usr/local/bin/docker",
        "/usr/bin/docker",
        "/opt/homebrew/bin/docker",
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".docker/bin/docker").path,
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".orbstack/bin/docker").path,
    ]

    func check(overridePath: String?) async -> DockerState {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: inspect(overridePath: overridePath))
            }
        }
    }

    private func inspect(overridePath: String?) -> DockerState {
        let paths = overridePath.map { [$0] } ?? searchPaths
        guard let path = paths.map({ NSString(string: $0).expandingTildeInPath })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return .cliNotFound
        }
        guard let contextData = run(path, arguments: ["context", "show"]) else { return .notRunning }
        let context = String(decoding: contextData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !context.isEmpty,
              let endpointData = run(path, arguments: ["context", "inspect", context, "--format", "{{json .Endpoints.docker.Host}}"]),
              let endpoint = try? JSONDecoder().decode(String.self, from: endpointData),
              endpoint.hasPrefix("unix:///"),
              let data = run(path, arguments: ["--host", endpoint, "info", "--format", "{{json .}}"]),
              let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .notRunning
        }
        let identity = (["OperatingSystem", "Name"].compactMap { info[$0] as? String } + [context])
            .joined(separator: " ").lowercased()
        let provider: String
        if identity.contains("orbstack") { provider = "OrbStack" }
        else if identity.contains("colima") { provider = "Colima" }
        else if identity.contains("docker desktop") || identity.contains("desktop-linux") { provider = "Docker Desktop" }
        else { provider = "Other" }
        let compose = run(path, arguments: ["--host", endpoint, "compose", "version", "--short"])
            .map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        return .running(provider: provider, composeAvailable: compose?.hasPrefix("2.") == true || compose?.hasPrefix("v2.") == true)
    }

    func run(_ path: String, arguments: [String]) -> Data? {
        guard let result = try? CommandOutput.run(path, arguments: arguments), result.status == 0 else { return nil }
        return result.data
    }
}
