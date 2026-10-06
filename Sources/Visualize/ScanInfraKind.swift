import Foundation

enum ScanInfraKind: String, Codable, Hashable {
    case postgres
    case mysql
    case mongodb
    case redis
    case sqlite
}
