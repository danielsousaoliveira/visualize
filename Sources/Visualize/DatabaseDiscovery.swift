import Foundation

struct DatabaseDiscovery {
    static func discover(project: Project, dockerOverride: String?) async -> (candidates: [DatabaseCandidate], warnings: [String]) {
        await Task.detached {
            var candidates: [DatabaseCandidate] = []
            var warnings: [String] = []
            let directories = ["."] + (project.lastResult?.services.map(\.rootDirectory) ?? [])
            var paths = Set<String>()
            for directory in directories {
                for name in [".env.development.local", ".env.local", ".env.development", ".env"] {
                    let relative = directory == "." ? name : "\(directory)/\(name)"
                    guard paths.insert(relative).inserted else { continue }
                    do {
                        let url = try DockerPath.resolve(relative, project: project)
                        guard FileManager.default.fileExists(atPath: url.path) else { continue }
                        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                        guard size <= 1_048_576 else { throw DatabaseError("Env file exceeds 1 MB") }
                        let values = envValues(try String(contentsOf: url, encoding: .utf8))
                        for key in ["DATABASE_URL", "POSTGRES_URL"] {
                            guard let value = values[key], !value.isEmpty else { continue }
                            if let candidate = try DatabaseCandidate.fromURL(value, source: "\(relative): \(key)", directory: url.deletingLastPathComponent()) {
                                candidates.append(candidate)
                            }
                        }
                    } catch { warnings.append("\(relative): \(error.localizedDescription)") }
                }
            }
            for file in project.lastResult?.composeFiles ?? [] {
                do {
                    let command = try DockerCommand.connect(overridePath: dockerOverride)
                    let url = try DockerPath.resolve(file, project: project)
                    let output = try CommandOutput.run(command.executable, arguments: ["--host", command.endpoint, "compose", "--project-directory", url.deletingLastPathComponent().path, "-f", url.path, "config", "--format", "json"], timeout: 10)
                    guard output.status == 0 else { throw DatabaseError("Could not resolve compose database configuration") }
                    candidates += try composeCandidates(output.data, source: file)
                } catch { warnings.append("\(file): \(error.localizedDescription)") }
            }
            return (candidates, warnings)
        }.value
    }

    static func envValues(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            var row = String(line).trimmingCharacters(in: .whitespaces)
            if row.hasPrefix("export ") { row = String(row.dropFirst(7)) }
            guard !row.hasPrefix("#"), let equals = row.firstIndex(of: "=") else { continue }
            let key = row[..<equals].trimmingCharacters(in: .whitespaces)
            var value = row[row.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if let quote = value.first, quote == "\"" || quote == "'" {
                var decoded = ""
                var escaped = false
                var closed = false
                for character in value.dropFirst() {
                    if escaped {
                        if quote == "\"" {
                            decoded += ["n": "\n", "r": "\r", "t": "\t", "\\": "\\", "\"": "\"", "$": "$" ][String(character)] ?? "\\\(character)"
                        } else { decoded += character == "'" ? "'" : "\\\(character)" }
                        escaped = false
                    } else if character == "\\" { escaped = true }
                    else if character == quote { closed = true; break }
                    else { decoded.append(character) }
                }
                guard closed else { continue }
                value = decoded
            } else if let range = value.range(of: " #") { value = String(value[..<range.lowerBound]).trimmingCharacters(in: .whitespaces) }
            values[key] = value
        }
        return values
    }

    static func composeCandidates(_ data: Data, source: String) throws -> [DatabaseCandidate] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let services = root["services"] as? [String: [String: Any]] else { return [] }
        return services.keys.sorted().compactMap { name in
            guard let service = services[name], let image = service["image"] as? String,
                  image.components(separatedBy: "/").last?.components(separatedBy: ":").first?.components(separatedBy: "@").first == "postgres",
                  let ports = service["ports"] as? [[String: Any]],
                  let mapping = ports.first(where: { String(describing: $0["target"] ?? "") == "5432" && ($0["protocol"] as? String ?? "tcp") == "tcp" }),
                  let port = Int(String(describing: mapping["published"] ?? "")) else { return nil }
            let environment = service["environment"] as? [String: String] ?? [:]
            var settings = DatabaseConnectionSettings()
            settings.name = name
            settings.port = port
            settings.user = environment["POSTGRES_USER"] ?? "postgres"
            settings.database = environment["POSTGRES_DB"] ?? settings.user
            return DatabaseCandidate(settings: settings, password: environment["POSTGRES_PASSWORD"] ?? "", source: "\(source): \(name)")
        }
    }
}
