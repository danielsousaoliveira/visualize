import Foundation

struct DockerContainerMonitor: Sendable {
    static let detailFormat = #"{"Id":{{json .Id}},"Name":{{json .Name}},"Config":{"Image":{{json .Config.Image}},"Labels":{{json .Config.Labels}}},"State":{"Running":{{json .State.Running}},"Status":{{json .State.Status}}},"NetworkSettings":{"Ports":{{json .NetworkSettings.Ports}}}}"#

    func scan(overridePath: String?) -> [DockerContainer] {
        guard let command = try? DockerCommand.connect(overridePath: overridePath),
              let result = try? run(command, ["ps", "--no-trunc", "--format", #"{"ID":{{json .ID}}}"#]), result.status == 0 else { return [] }
        let ids = String(decoding: result.data, as: UTF8.self).split(separator: "\n").compactMap { line -> String? in
            guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = row["ID"] as? String, id.count == 64, id.allSatisfy({ $0.isHexDigit }) else { return nil }
            return id
        }
        return stride(from: 0, to: ids.count, by: 16).flatMap { offset in
            inspect(command, ids: Array(ids.dropFirst(offset).prefix(16)))
        }
    }

    private func inspect(_ command: DockerCommand, ids: [String]) -> [DockerContainer] {
        guard !ids.isEmpty else { return [] }
        if let details = try? run(command, ["inspect", "--format", Self.detailFormat] + ids), details.status == 0 {
            let rows = String(decoding: details.data, as: UTF8.self).split(separator: "\n").joined(separator: ",")
            if let containers = try? DockerContainer.decode(Data("[\(rows)]".utf8)) { return containers }
        }
        guard ids.count > 1 else { return [] }
        let midpoint = ids.count / 2
        return inspect(command, ids: Array(ids.prefix(midpoint))) + inspect(command, ids: Array(ids.dropFirst(midpoint)))
    }

    func perform(_ action: String, containerID: String, allowedContainerIDs: Set<String>, overridePath: String?) throws {
        guard ["stop", "restart"].contains(action), containerID.count == 64, containerID.allSatisfy({ $0.isHexDigit }),
              allowedContainerIDs.contains(containerID) else {
            throw NSError(domain: "Container is not in the displayed monitor results", code: 1)
        }
        let command = try DockerCommand.connect(overridePath: overridePath)
        guard inspect(command, ids: [containerID]).contains(where: { $0.id == containerID }) else {
            throw NSError(domain: "Container is no longer running with a published TCP port", code: 1)
        }
        let result = try run(command, [action, containerID], timeout: 30)
        guard result.status == 0 else { throw NSError(domain: "Docker container action failed", code: 1) }
    }

    private func run(_ command: DockerCommand, _ arguments: [String], timeout: TimeInterval = 5) throws -> CommandOutput {
        try CommandOutput.run(command.executable, arguments: ["--host", command.endpoint] + arguments, timeout: timeout)
    }

    static func merge(processes: [ProcessListener], containers: [DockerContainer], projects: [Project], ports: ClosedRange<Int>?) -> [ProcessListener] {
        guard let ports else { return [] }
        let local = processes.filter { !isProvider($0) }
        return (local + containers.flatMap { $0.listeners(projects: projects) }.filter { ports.contains($0.port) })
            .sorted { $0.port == $1.port ? $0.id < $1.id : $0.port < $1.port }
    }

    static func isProvider(_ listener: ProcessListener) -> Bool {
        let name = listener.executablePath.map { URL(filePath: $0).lastPathComponent } ?? listener.name
        return ["com.docker.backend", "com.docker.backend.exe", "vpnkit", "orb", "orbstack", "OrbStack", "orb-stack", "com.orbstack.helper"].contains(name)
            || listener.executablePath?.contains("/OrbStack.app/") == true
            || listener.executablePath?.contains("/Docker.app/") == true
    }
}
