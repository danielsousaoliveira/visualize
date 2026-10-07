import Foundation
import Observation

@MainActor
@Observable
final class ServiceRun {
    var docker: DockerRun?
    var busy = false
    var monitoringDocker = false
    var lastOutputLines: String { String(decoding: output, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).suffix(20).joined(separator: "\n") }
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
