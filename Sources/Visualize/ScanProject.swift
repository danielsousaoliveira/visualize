import Foundation

struct ScanProject: Codable, Hashable {
    var name: String
    var rootPath: String
    var gitBranch: String?
    var type: ScanProjectType
}
