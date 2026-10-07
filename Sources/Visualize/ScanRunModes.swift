import Foundation

struct ScanRunModes: Codable, Hashable {
    var local: ScanRunMode
    var compose: ScanComposeRunMode
    var dockerfile: ScanDockerfileRunMode
}
