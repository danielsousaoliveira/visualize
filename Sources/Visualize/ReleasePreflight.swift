import Foundation

struct ReleasePreflight: Sendable {
    let settings: ReleaseSettings
    let mainSHA: String
    let productionSHA: String?
    let incoming: [String]
    let outgoing: [String]
    var unchanged: Bool { mainSHA == productionSHA }
    var pushExplanation: String {
        let source = "\(settings.remote)/\(settings.main)"
        let target = "\(settings.remote)/\(settings.production)"
        let action: String
        if productionSHA == nil {
            action = "Create \(target) at the reviewed \(source) commit \(mainSHA)."
        } else if outgoing.isEmpty {
            action = "Advance \(target) to the reviewed \(source) commit \(mainSHA), adding \(incoming.count) commit(s)."
        } else {
            action = "Replace \(target) with the reviewed \(source) commit \(mainSHA). The \(outgoing.count) production-only commit(s) listed in the review will be removed from that branch. The push will be rejected if the remote production branch has changed since review."
        }
        return action + " An existing local production branch will also be updated unless it is checked out in a worktree. Your working files and current checkout stay in place. Any deployment configured for the remote production branch may run."
    }

    var requiresConfirmation: Bool { productionSHA == nil || !outgoing.isEmpty }
}
