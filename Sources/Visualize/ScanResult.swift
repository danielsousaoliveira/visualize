import Foundation

struct ScanResult: Codable, Hashable {
    var schemaVersion: Int
    var project: ScanProject
    var services: [ScanService]
    var composeFiles: [String]
    var composeServices: [ScanComposeService]
    var infra: [ScanInfra]
    var warnings: [String]

    var summary: String {
        let header = "\(project.name) (\(project.type.rawValue)) at \(project.rootPath)"
        let serviceLines = services.map { service in
            let details = [service.stackId ?? "unknown stack", service.port.map { "port \($0)" }]
                .compactMap { $0 }
                .joined(separator: ", ")
            return "• \(service.name) — \(details)"
        }
        let warningLines = warnings.map { "⚠ \($0)" }
        return ([header] + serviceLines + warningLines).joined(separator: "\n")
    }
}
