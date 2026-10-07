import Foundation

struct ScanConnection: Codable, Hashable {
    var from: String
    var to: String
    var kind: ScanConnectionKind
    var label: String
}
