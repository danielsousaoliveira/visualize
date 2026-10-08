import Foundation

struct ReleaseSettings: Codable, Hashable, Sendable {
    var main = ""
    var production = ""
    var remote = "origin"
}
