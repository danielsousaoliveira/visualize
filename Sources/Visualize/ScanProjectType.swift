import Foundation

enum ScanProjectType: String, Codable, Hashable {
    case app
    case monorepo
    case services
    case docker
}
