import Foundation

struct ScanDevCommand: Codable, Hashable {
    var argv: [String]
    var workingDirectory: String
    var source: String
}
