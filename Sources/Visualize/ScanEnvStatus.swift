import Foundation

enum ScanEnvStatus: String, Codable, Hashable {
    case set
    case missing
    case extra
}
