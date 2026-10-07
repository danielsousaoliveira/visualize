import Foundation

struct ScanService: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var kind: ScanServiceKind
    var rootDirectory: String
    var stackId: String?
    var category: String?
    var packageManager: String?
    var installCommand: String?
    var buildCommand: String?
    var startCommand: String?
    var port: Int?
    var hasDockerfile: Bool
    var devCommand: ScanDevCommand?
    var runModes: ScanRunModes

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, rootDirectory, stackId, category, packageManager, installCommand, buildCommand, startCommand, port, hasDockerfile, devCommand, runModes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(ScanServiceKind.self, forKey: .kind)
        rootDirectory = try container.decode(String.self, forKey: .rootDirectory)
        stackId = try container.decodeIfPresent(String.self, forKey: .stackId)
        category = try container.decodeIfPresent(String.self, forKey: .category)
        packageManager = try container.decodeIfPresent(String.self, forKey: .packageManager)
        installCommand = try container.decodeIfPresent(String.self, forKey: .installCommand)
        buildCommand = try container.decodeIfPresent(String.self, forKey: .buildCommand)
        startCommand = try container.decodeIfPresent(String.self, forKey: .startCommand)
        port = try container.decodeIfPresent(Int.self, forKey: .port)
        hasDockerfile = try container.decode(Bool.self, forKey: .hasDockerfile)
        devCommand = try container.decodeIfPresent(ScanDevCommand.self, forKey: .devCommand)
        runModes = try container.decodeIfPresent(ScanRunModes.self, forKey: .runModes) ?? ScanRunModes(
            local: ScanRunMode(available: devCommand != nil, reason: devCommand == nil ? "no dev command detected" : nil),
            compose: ScanComposeRunMode(available: false, reason: "rescan required", composeFile: nil, serviceName: nil),
            dockerfile: ScanDockerfileRunMode(available: false, reason: "rescan required", dockerfilePath: nil, containerPort: nil)
        )
    }
}
