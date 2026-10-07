import Foundation

struct ScanDockerfileRunMode: Codable, Hashable {
    var available: Bool
    var reason: String?
    var dockerfilePath: String?
    var containerPort: Int?
}
