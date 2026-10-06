import Foundation

struct ScanInfra: Codable, Hashable {
    var kind: ScanInfraKind
    var usedBy: [String]
    var providedBy: String?
    var evidence: [String]
    var host: String?
    var port: Int?
}
