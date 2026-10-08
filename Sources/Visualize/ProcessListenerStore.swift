import Foundation

@MainActor
@Observable
final class ProcessListenerStore {
    private(set) var listeners: [ProcessListener] = []
    private(set) var lastScan: Date?
    var lowerPort = 1024
    var upperPort = 65535
    private let monitor = ProcessListenerMonitor()
    private var task: Task<Void, Never>?

    func start(projects: @escaping @MainActor () -> [Project]) {
        guard task == nil else { return }
        task = Task {
            while !Task.isCancelled {
                let currentProjects = projects()
                let lower = min(65535, max(1, lowerPort))
                let upper = min(65535, max(1, upperPort))
                let results: [ProcessListener]
                if lower > upper {
                    results = []
                } else {
                    let range = lower...upper
                    let sampler = self.monitor
                    results = await Task.detached(priority: .utility) { sampler.scan(ports: range, projects: currentProjects) }.value
                }
                listeners = results
                lastScan = Date()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}
