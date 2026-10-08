import Foundation

@MainActor
@Observable
final class ProcessListenerStore {
    private(set) var listeners: [ProcessListener] = []
    private(set) var lastScan: Date?
    var lowerPort = 1024
    var upperPort = 65535
    private(set) var actionError: String?
    private(set) var busyContainers: Set<String> = []
    private var processes: [ProcessListener] = []
    private var containers: [DockerContainer] = []
    private var dockerTask: Task<Void, Never>?
    private let monitor = ProcessListenerMonitor()
    private var task: Task<Void, Never>?

    func start(projects: @escaping @MainActor () -> [Project], dockerOverride: @escaping @MainActor () -> String? = { nil }) {
        guard task == nil else { return }
        dockerTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    guard let self else { return }
                    let override = dockerOverride()
                    let result = await Task.detached(priority: .utility) { DockerContainerMonitor().scan(overridePath: override) }.value
                    guard !Task.isCancelled else { return }
                    containers = result
                    merge(projects: projects())
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
        task = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    guard let self else { return }
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
                    guard !Task.isCancelled else { return }
                    processes = results
                    merge(projects: currentProjects)
                    lastScan = Date()
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() {
        task?.cancel()
        dockerTask?.cancel()
        task = nil
        dockerTask = nil
    }

    private func merge(projects: [Project]) {
        let lower = min(65535, max(1, lowerPort))
        let upper = min(65535, max(1, upperPort))
        listeners = DockerContainerMonitor.merge(processes: processes, containers: containers, projects: projects,
                                                 ports: lower <= upper ? lower...upper : nil)
    }

    func perform(_ action: String, container: DockerContainer, overridePath: String?) async {
        guard busyContainers.insert(container.id).inserted else { return }
        defer { busyContainers.remove(container.id) }
        actionError = nil
        do {
            try await Task.detached(priority: .utility) {
                try DockerContainerMonitor().perform(action, containerID: container.id, overridePath: overridePath)
            }.value
            if action == "stop" {
                containers.removeAll { $0.id == container.id }
                listeners.removeAll { $0.container?.id == container.id }
            }
        } catch { actionError = error.localizedDescription }
    }
}
