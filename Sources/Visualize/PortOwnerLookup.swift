import Foundation
import Darwin

struct PortOwnerLookup {
    static func owners(port: Int, dockerOverridePath: String? = nil, includeDocker: Bool = true) throws -> [PortOwner] {
        guard (1...65535).contains(port) else { throw NSError(domain: "Invalid port", code: 1) }
        let process = Process()
        process.executableURL = URL(filePath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpcu"]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 || (process.terminationStatus == 1 && data.isEmpty) else {
            throw NSError(domain: "Could not check port \(port)", code: 1)
        }
        var records: [(Int32, String, UInt32?)] = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let value = String(line.dropFirst())
            switch line.first {
            case "p": if let pid = Int32(value) { records.append((pid, "Unknown process", nil)) }
            case "c": if !records.isEmpty { records[records.count - 1].1 = value }
            case "u": if !records.isEmpty { records[records.count - 1].2 = UInt32(value) }
            default: break
            }
        }
        var owners = records.map { pid, name, uid in
            var info = proc_bsdinfo()
            let identified = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size
            var vnodes = proc_vnodepathinfo()
            let hasDirectory = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnodes, Int32(MemoryLayout<proc_vnodepathinfo>.size)) == MemoryLayout<proc_vnodepathinfo>.size
            let directory = hasDirectory ? withUnsafePointer(to: &vnodes.pvi_cdir.vip_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            } : nil
            return PortOwner(port: port, pid: pid, name: name, uid: identified ? info.pbi_uid : uid,
                             seconds: identified ? info.pbi_start_tvsec : nil, microseconds: identified ? info.pbi_start_tvusec : nil,
                             workingDirectory: directory)
        }
        guard includeDocker else { return owners }
        let checker = DockerChecker()
        let paths = (dockerOverridePath.map { [$0] } ?? []) + checker.searchPaths
        guard let path = paths.map({ NSString(string: $0).expandingTildeInPath }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
              let contextData = checker.run(path, arguments: ["context", "show"]),
              let endpointData = checker.run(path, arguments: ["context", "inspect", String(decoding: contextData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), "--format", "{{json .Endpoints.docker.Host}}"]),
              let endpoint = try? JSONDecoder().decode(String.self, from: endpointData), endpoint.hasPrefix("unix:///"),
              let idsData = checker.run(path, arguments: ["--host", endpoint, "ps", "-q"]) else { return owners }
        let ids = String(decoding: idsData, as: UTF8.self).split(separator: "\n").map(String.init)
        guard !ids.isEmpty,
              let details = checker.run(path, arguments: ["--host", endpoint, "inspect", "--format", "{\"Id\":{{json .Id}},\"Name\":{{json .Name}},\"Ports\":{{json .NetworkSettings.Ports}},\"ComposeProject\":{{json (index .Config.Labels \"com.docker.compose.project\")}}}"] + ids) else { return owners }
        let containers = details.split(separator: 10).compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
        var containerOwners: [PortOwner] = []
        for container in containers {
            guard let ports = container["Ports"] as? [String: Any],
                  ports.contains(where: { key, value in
                      key.hasSuffix("/tcp") && (value as? [[String: String]])?.contains(where: { $0["HostPort"] == String(port) }) == true
                  }), let id = container["Id"] as? String, let name = container["Name"] as? String else { continue }
            var owner = PortOwner(port: port, pid: 0, name: "Docker", uid: nil, seconds: nil, microseconds: nil, workingDirectory: nil)
            owner.containerID = id
            owner.containerName = String(name.drop(while: { $0 == "/" }))
            owner.composeProject = (container["ComposeProject"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            containerOwners.append(owner)
        }
        if !containerOwners.isEmpty {
            owners.removeAll { ["com.docker", "com.dock", "docker-proxy", "dockerd", "orbstack"].contains(where: $0.name.lowercased().hasPrefix) }
            owners.append(contentsOf: containerOwners)
        }
        return owners
    }

}
