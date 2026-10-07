import Foundation
import Darwin

struct PortOwnerLookup {
    static func owners(port: Int, dockerOverridePath: String? = nil, includeDocker: Bool = true) throws -> [PortOwner] {
        guard (1...65535).contains(port) else { throw NSError(domain: "Invalid port", code: 1) }
        let result = try CommandOutput.run("/usr/sbin/lsof", arguments: ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpcu"])
        let data = result.data
        guard result.status == 0 || (result.status == 1 && data.isEmpty) else {
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
        let containers: [[String: Any]]
        do {
            containers = try dockerContainers(overridePath: dockerOverridePath)
        } catch {
            if dockerOverridePath != nil { throw error }
            return owners
        }
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
        owners.append(contentsOf: containerOwners)
        return owners
    }

    private static func dockerContainers(overridePath: String?) throws -> [[String: Any]] {
        let paths = overridePath.map { [$0] } ?? DockerChecker().searchPaths
        guard let path = paths.map({ NSString(string: $0).expandingTildeInPath }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw NSError(domain: "Docker owner lookup failed: executable unavailable", code: 1)
        }
        func run(_ arguments: [String]) throws -> Data {
            let result = try CommandOutput.run(path, arguments: arguments)
            guard result.status == 0 else { throw NSError(domain: "Docker owner lookup failed: \(arguments.first ?? "command")", code: Int(result.status)) }
            return result.data
        }
        let context = String(decoding: try run(["context", "show"]), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !context.isEmpty else { throw NSError(domain: "Docker owner lookup failed: no context", code: 1) }
        let endpointData = try run(["context", "inspect", context, "--format", "{{json .Endpoints.docker.Host}}"])
        guard let endpoint = try? JSONDecoder().decode(String.self, from: endpointData), endpoint.hasPrefix("unix:///") else {
            throw NSError(domain: "Docker owner lookup failed: local endpoint required", code: 1)
        }
        let ids = String(decoding: try run(["--host", endpoint, "ps", "-q"]), as: UTF8.self).split(separator: "\n").map(String.init)
        guard !ids.isEmpty else { return [] }
        let details = try run(["--host", endpoint, "inspect", "--format", "{\"Id\":{{json .Id}},\"Name\":{{json .Name}},\"Ports\":{{json .NetworkSettings.Ports}},\"ComposeProject\":{{json (index .Config.Labels \"com.docker.compose.project\")}}}"] + ids)
        return try details.split(separator: 10).map {
            guard let container = try JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] else {
                throw NSError(domain: "Docker owner lookup failed: invalid container metadata", code: 1)
            }
            return container
        }
    }

}
