import Foundation

@MainActor
@Observable
final class ProcessListenerStore {
    private(set) var listeners: [ProcessListener] = []
    private(set) var lastScan: Date?
    var scanInterval = 2
    var lowerPort = 1024
    var upperPort = 65535
    private(set) var actionError: String?
    private(set) var busyContainers: Set<String> = []
    private(set) var dockerOwnership: String?
    private var processes: [ProcessListener] = []
    private var scannedDockerOverride: String?
    private var containers: [DockerContainer] = []
    private var dockerTask: Task<Void, Never>?
    private let monitor = ProcessListenerMonitor()
    private var task: Task<Void, Never>?

    func start(dockerOwnership: String? = nil, projects: @escaping @MainActor () -> [Project], ownedAttribution: @escaping @MainActor (ProcessListener) -> ProcessListener? = { _ in nil }, dockerOverride: @escaping @MainActor () -> String? = { nil }) {
        guard task == nil else { return }
        self.dockerOwnership = dockerOwnership
        dockerTask = Task { [weak self] in
            while !Task.isCancelled {
                let cycleStarted = ContinuousClock.now
                do {
                    guard let self else { return }
                    let override = dockerOverride()
                    let result = await Task.detached(priority: .utility) { DockerContainerMonitor().scan(overridePath: override) }.value
                    guard !Task.isCancelled else { return }
                    scannedDockerOverride = override
                    containers = result
                    merge(projects: projects(), ownedAttribution: ownedAttribution)
                }
                await self?.waitForNextScan(since: cycleStarted)
            }
        }
        task = Task { [weak self] in
            while !Task.isCancelled {
                let cycleStarted = ContinuousClock.now
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
                    merge(projects: projects(), ownedAttribution: ownedAttribution)
                    lastScan = Date()
                }
                await self?.waitForNextScan(since: cycleStarted)
            }
        }
    }

    private func waitForNextScan(since started: ContinuousClock.Instant) async {
        while !Task.isCancelled, started.duration(to: .now) < .seconds(scanInterval) {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    func configure(interval: Int, lower: Int, upper: Int) {
        scanInterval = interval
        lowerPort = lower
        upperPort = upper
        processes.removeAll { !(lower...upper).contains($0.port) }
        listeners.removeAll { !(lower...upper).contains($0.port) }
    }

    func stop() {
        task?.cancel()
        dockerTask?.cancel()
        task = nil
        dockerTask = nil
    }

    private func merge(projects: [Project], ownedAttribution: (ProcessListener) -> ProcessListener?) {
        let lower = min(65535, max(1, lowerPort))
        let upper = min(65535, max(1, upperPort))
        listeners = DockerContainerMonitor.merge(processes: processes.map { ownedAttribution($0) ?? PortAttribution.resolve($0, projects: projects) }, containers: containers, projects: projects,
                                                 ports: lower <= upper ? lower...upper : nil, dockerOwnership: dockerOwnership)
            .filter { lower <= $0.port && $0.port <= upper }
    }

    func perform(_ action: String, container: DockerContainer, overridePath: String?) async {
        let allowedIDs = Set(listeners.compactMap { $0.container?.id }).intersection(containers.map(\.id))
        guard allowedIDs.contains(container.id), scannedDockerOverride == overridePath else {
            actionError = "Container is no longer in the displayed monitor results"
            return
        }
        guard containers.first(where: { $0.id == container.id }) == container,
              listeners.filter({ $0.container?.id == container.id }).allSatisfy({ $0.container == container }) else {
            actionError = "Container details changed; review the current monitor entry before acting"
            return
        }
        guard action != "restart" || listeners.contains(where: { $0.container?.id == container.id && $0.startedByVisualize }) else {
            actionError = "Visualize can only restart containers it started"
            return
        }
        guard busyContainers.insert(container.id).inserted else { return }
        defer { busyContainers.remove(container.id) }
        actionError = nil
        let ownership = dockerOwnership
        do {
            try await Task.detached(priority: .utility) {
                try DockerContainerMonitor().perform(action, containerID: container.id, allowedContainerIDs: allowedIDs, overridePath: overridePath, expectedContainer: container, dockerOwnership: ownership)
            }.value
            if action == "stop" {
                containers.removeAll { $0.id == container.id }
                listeners.removeAll { $0.container?.id == container.id }
            }
        } catch { actionError = error.localizedDescription }
    }
}
