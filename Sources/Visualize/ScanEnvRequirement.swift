import Foundation

struct ScanEnvRequirement: Codable, Hashable {
    var serviceId: String
    var variables: [ScanEnvVariable]
}
