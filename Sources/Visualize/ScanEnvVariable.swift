import Foundation

struct ScanEnvVariable: Codable, Hashable {
    var name: String
    var status: ScanEnvStatus
    var declaredIn: [String]
}
