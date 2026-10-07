import Foundation

enum DockerState: Equatable, Sendable {
    case checking
    case cliNotFound
    case notRunning
    case running(provider: String, composeAvailable: Bool)

    var message: String {
        switch self {
        case .checking: "Checking Docker…"
        case .cliNotFound: "Docker CLI not found"
        case .notRunning: "Docker is installed but not running"
        case .running(let provider, _): "Docker Running • \(provider)"
        }
    }

    func unavailableReason(compose: Bool = false) -> String? {
        guard case .running(_, let available) = self else { return message }
        return compose && !available ? "Docker Compose v2 plugin is missing" : nil
    }
}
