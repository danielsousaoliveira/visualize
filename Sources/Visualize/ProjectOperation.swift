import Foundation
import Observation

@MainActor
@Observable
final class ProjectOperation {
    var action = "Starting services"
    var completion = "Services started"
    var busy = true
    var statuses: [String: String] = [:]
    var warnings: [String] = []
    var order: [String] = []
}
