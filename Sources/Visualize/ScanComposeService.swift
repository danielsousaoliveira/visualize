import Foundation

struct ScanComposeService: Codable, Hashable {
    var name: String
    var image: String?
    var buildContext: String?
    var ports: [ScanPortMapping]
    var dependsOn: [String]
    var environment: [String]
    var composeFile: String? = nil
}
