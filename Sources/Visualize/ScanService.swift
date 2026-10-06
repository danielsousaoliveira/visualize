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
}
