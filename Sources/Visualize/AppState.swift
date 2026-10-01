import Observation

@MainActor
@Observable
final class AppState {
    var projects: [Project] = []
    var runningServices: [RunningService] = []
}
