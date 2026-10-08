import Foundation

struct DockerContainer: Sendable, Equatable {
    let id: String
    let name: String
    let image: String
    let status: String
    let ports: [Int]
    let labels: [String: String]

    var startedAt: Date? = nil

    var composeProject: String? { labels["com.docker.compose.project"] }
    var composeService: String? { labels["com.docker.compose.service"] }
    var workingDirectory: String? { labels["com.docker.compose.project.working_dir"] }
    var visualizeProject: String? { labels["visualize.project"] }
    var visualizeService: String? { labels["visualize.service"] }

    func isOwned(by token: String?) -> Bool {
        guard let token, !token.isEmpty else { return false }
        return labels["visualize.owner"] == token && visualizeProject?.isEmpty == false && visualizeService?.isEmpty == false
    }

    static func decode(_ data: Data) throws -> [Self] {
        let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let id = row["Id"] as? String, id.count == 64, id.allSatisfy({ $0.isHexDigit }),
                  let config = row["Config"] as? [String: Any], let image = config["Image"] as? String,
                  let state = row["State"] as? [String: Any], state["Running"] as? Bool == true else { return nil }
            let network = row["NetworkSettings"] as? [String: Any]
            let bindings = network?["Ports"] as? [String: Any] ?? [:]
            let ports = Set(bindings.filter { $0.key.hasSuffix("/tcp") }.values.flatMap { value -> [Int] in
                (value as? [[String: String]] ?? []).compactMap { binding in
                    guard let text = binding["HostPort"], let port = Int(text), (1...65535).contains(port) else { return nil }
                    return port
                }
            }).sorted()
            guard !ports.isEmpty else { return nil }
            return Self(id: id, name: String((row["Name"] as? String ?? id).drop(while: { $0 == "/" })),
                        image: image, status: state["Status"] as? String ?? "running", ports: ports,
                        labels: config["Labels"] as? [String: String] ?? [:], startedAt: (state["StartedAt"] as? String).flatMap { text in
                            let formatter = ISO8601DateFormatter()
                            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                            return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
                        })
        }
    }

    func listeners(projects: [Project], dockerOwnership: String? = nil) -> [ProcessListener] {
        return ports.map { port in
            PortAttribution.resolve(ProcessListener(port: port, pid: 0, name: name, executablePath: nil,
                            workingDirectory: workingDirectory, startedAt: nil,
                            cpuPercent: nil, memoryBytes: nil,
                            projectName: visualizeProject ?? composeProject,
                            projectFolder: workingDirectory, gitBranch: nil,
                            container: self), projects: projects, dockerOwnership: dockerOwnership)
        }
    }
}
