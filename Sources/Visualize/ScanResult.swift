import Foundation

struct ScanResult: Codable, Hashable {
    var schemaVersion: Int
    var project: ScanProject
    var services: [ScanService]
    var composeFiles: [String]
    var composeServices: [ScanComposeService]
    var warnings: [String]
}
