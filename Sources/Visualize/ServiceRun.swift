import Foundation
import Observation

@MainActor
@Observable
final class ServiceRun {
    let recipe: RunRecipe
    var status = "Starting"
    var pid: Int32?
    var group: OwnedProcessGroup?
    var stopping = false
    var leaderReaped = false
    var runningID: UUID?
    var launchEnvironment: [String: String] = [:]
    var portReady = false
    var output = Data()
    var outputFinished = false
    var hasBindFailure: Bool {
        let text = String(decoding: output, as: UTF8.self).lowercased()
        return text.contains("eaddrinuse") || text.contains("address already in use")
    }

    func finishOutput() { outputFinished = true }
    var active = true

    init(recipe: RunRecipe) { self.recipe = recipe }

    func append(_ data: Data) {
        output.append(data)
        if output.count > 1_048_576 { output.removeFirst(output.count - 1_048_576) }
    }
}
