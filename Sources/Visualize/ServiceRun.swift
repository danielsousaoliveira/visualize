import Foundation
import Observation

@MainActor
@Observable
final class ServiceRun {
    let recipe: RunRecipe
    var status = "Starting"
    var pid: Int32?
    var portReady = false
    var output = Data()
    var active = true

    init(recipe: RunRecipe) { self.recipe = recipe }

    func append(_ data: Data) {
        output.append(data)
        if output.count > 1_048_576 { output.removeFirst(output.count - 1_048_576) }
    }
}
