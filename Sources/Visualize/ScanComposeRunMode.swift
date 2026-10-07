import Foundation

struct ScanComposeRunMode: Codable, Hashable {
    var available: Bool
    var reason: String?
    var composeFile: String?
    var serviceName: String?
}
