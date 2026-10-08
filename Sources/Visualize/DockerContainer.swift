import Foundation

struct DockerContainer: Sendable {
    let id: String
    let name: String
    let image: String
    let status: String
    let ports: [Int]
    let labels: [String: String]

    var composeProject: String? { labels["com.docker.compose.project"] }
    var composeService: String? { labels["com.docker.compose.service"] }
    var workingDirectory: String? { labels["com.docker.compose.project.working_dir"] }
    var visualizeProject: String? { labels["visualize.project"] }
    var visualizeService: String? { labels["visualize.service"] }

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
                        labels: config["Labels"] as? [String: String] ?? [:])
        }
    }

    func listeners(projects: [Project]) -> [ProcessListener] {
        let project = projects.first { $0.id.uuidString == labels["visualize.library"] }
            ?? projects.first { $0.folderPath == workingDirectory }
        return ports.map { port in
            ProcessListener(port: port, pid: 0, name: name, executablePath: nil,
                            workingDirectory: workingDirectory ?? project?.folderPath, startedAt: nil,
                            cpuPercent: nil, memoryBytes: nil,
                            projectName: project?.name ?? visualizeProject ?? composeProject,
                            projectFolder: project?.folderPath ?? workingDirectory, gitBranch: project?.lastResult?.project.gitBranch,
                            container: self)
        }
    }
}
