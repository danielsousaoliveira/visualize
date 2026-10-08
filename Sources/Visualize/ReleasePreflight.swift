import Foundation

struct ReleasePreflight: Sendable {
    let settings: ReleaseSettings
    let mainSHA: String
    let productionSHA: String?
    let incoming: [String]
    let outgoing: [String]
    var unchanged: Bool { mainSHA == productionSHA }
    var requiresConfirmation: Bool { productionSHA == nil || !outgoing.isEmpty }
}
