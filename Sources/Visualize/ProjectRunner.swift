import Foundation

extension AppState {
    func startAll(project: Project, mode: ProjectStartMode) async {
        guard projectOperations[project.id]?.busy != true, let result = project.lastResult else { return }
        projectRunResults[project.id] = result
        let operation = ProjectOperation()
        projectOperations[project.id] = operation
        defer { operation.busy = false }
        let services = Dictionary(result.services.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let modes = services.compactMapValues { mode.resolve($0, remembered: self.mode(project: project, service: $0)) }
        let original = ProjectRunPlan(result: result)
        var dependencies = original.dependencies
        let composeGroups = Dictionary(grouping: result.services.filter { modes[$0.id] == .compose && serviceRuns[runKey(project: project, service: $0)]?.active != true }, by: { $0.runModes.compose.composeFile ?? "" })
        if mode == .docker {
            for group in composeGroups.values {
                for service in group { dependencies[service.id, default: []].formUnion(group.map(\.id).filter { $0 != service.id }) }
            }
        }
        let plan = ProjectRunPlan(ids: result.services.map(\.id), dependencies: dependencies)
        operation.order = plan.layers.flatMap { $0.flatMap { $0 } }
        operation.warnings = original.cycles.map { "Dependency cycle: \($0.compactMap { services[$0]?.name }.joined(separator: ", ")). Starting together." }
        for service in result.services { operation.statuses[service.id] = "waiting" }
        for layer in plan.layers {
            await withTaskGroup(of: Void.self) { tasks in
                for component in layer {
                    tasks.addTask { await self.startComponent(component, project: project, services: services, modes: modes, plan: plan, operation: operation, batchCompose: mode == .docker) }
                }
            }
        }
    }

    private func startComponent(_ component: [String], project: Project, services: [String: ScanService], modes: [String: ServiceMode], plan: ProjectRunPlan, operation: ProjectOperation, batchCompose: Bool) async {
        await withTaskGroup(of: Void.self) { tasks in
            var submittedFiles: Set<String> = []
            for id in component {
                guard let service = services[id] else { continue }
                if serviceRuns[runKey(project: project, service: service)]?.active == true {
                    operation.statuses[id] = "already running"
                    continue
                }
                let batch: [ScanService]
                if batchCompose, modes[id] == .compose, let file = service.runModes.compose.composeFile {
                    guard submittedFiles.insert(file).inserted else { continue }
                    batch = component.compactMap { services[$0] }.filter { modes[$0.id] == .compose && $0.runModes.compose.composeFile == file && serviceRuns[runKey(project: project, service: $0)]?.active != true }
                } else { batch = [service] }
                tasks.addTask { await self.startBatch(batch, component: component, project: project, services: services, modes: modes, plan: plan, operation: operation) }
            }
        }
    }

    private func startBatch(_ batch: [ScanService], component: [String], project: Project, services: [String: ScanService], modes: [String: ServiceMode], plan: ProjectRunPlan, operation: ProjectOperation) async {
        let dependencies = Set(batch.flatMap { plan.dependencies[$0.id, default: []] }).subtracting(component)
        for id in dependencies.sorted() {
            guard let dependency = services[id] else { continue }
            let failed = operation.statuses[id]?.hasPrefix("failed") == true || operation.statuses[id]?.hasPrefix("blocked") == true
            let ready = failed ? false : await waitUntilReady(project: project, service: dependency)
            if !ready {
                if !failed {
                    let run = serviceRuns[runKey(project: project, service: dependency)]
                    let reason = run?.active == true ? "Port \(dependency.port.map(String.init) ?? "unknown") did not accept TCP within 60 seconds" : run?.status ?? "not started or unavailable"
                    operation.statuses[id] = "failed — \(reason)"
                }
                for service in batch { operation.statuses[service.id] = "blocked by \(dependency.name)" }
                return
            }
        }
        guard let service = batch.first, let selected = modes[service.id] else {
            for service in batch { operation.statuses[service.id] = "unavailable — no matching run mode" }
            return
        }
        for item in batch { operation.statuses[item.id] = "starting" }
        if selected == .local, let recipe = recipe(project: project, service: service) {
            await start(project: project, service: service, recipe: recipe)
        } else if selected != .local {
            await startDocker(project: project, service: service, selectedMode: selected, composeServices: batch, parallel: true)
        }
        for item in batch {
            let run = serviceRuns[runKey(project: project, service: item)]
            operation.statuses[item.id] = run?.active == true ? "running" : "failed — \(run?.status ?? "run mode unavailable")"
        }
    }

    private func waitUntilReady(project: Project, service: ScanService) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        repeat {
            guard let run = serviceRuns[runKey(project: project, service: service)], run.active else { return false }
            if let port = service.port {
                if await Task.detached(operation: { TCPProbe.accepts(port: port) }).value { return true }
            } else { return !run.busy && (run.pid != nil || run.docker != nil) }
            try? await Task.sleep(for: .milliseconds(200))
        } while ContinuousClock.now < deadline
        return false
    }

    func stopAll(project: Project) async {
        guard projectOperations[project.id]?.busy != true, var result = project.lastResult ?? projectRunResults[project.id] else { return }
        let known = Set(result.services.map(\.id))
        result.services += (launchedServices[project.id] ?? [:]).values.filter { !known.contains($0.id) }.sorted { $0.id < $1.id }
        if let previous = projectRunResults[project.id] {
            result.connections += previous.connections.filter { !result.connections.contains($0) }
            result.infra += previous.infra.filter { entry in !result.infra.contains { $0.id == entry.id } }
        }
        let operation = ProjectOperation()
        operation.action = "Stopping services"
        operation.completion = "Services stopped"
        projectOperations[project.id] = operation
        defer { operation.busy = false }
        let plan = ProjectRunPlan(result: result)
        operation.order = plan.layers.reversed().flatMap { $0.flatMap { $0 } }
        let managed = Set(result.services.filter {
            let run = serviceRuns[runKey(project: project, service: $0)]
            return run?.active == true || run?.docker != nil
        }.map(\.id))
        operation.order = operation.order.filter { managed.contains($0) }
        for id in operation.order { operation.statuses[id] = "waiting" }
        for layer in plan.layers.reversed() {
            await withTaskGroup(of: Void.self) { tasks in
                for id in layer.flatMap({ $0 }) where managed.contains(id) {
                    guard let service = result.services.first(where: { $0.id == id }) else { continue }
                    tasks.addTask { await self.stopProjectService(project: project, service: service, operation: operation) }
                }
            }
        }
    }

    private func stopProjectService(project: Project, service: ScanService, operation: ProjectOperation) async {
        guard let run = serviceRuns[runKey(project: project, service: service)], run.active || run.docker != nil else {
            operation.statuses[service.id] = "not managed by visualize"
            return
        }
        operation.statuses[service.id] = "stopping"
        if run.docker != nil {
            while dockerOperationBusy(project.id) { try? await Task.sleep(for: .milliseconds(50)) }
        }
        await stop(project: project, service: service)
        let cleaned = await removeStoppedContainers(run)
        operation.statuses[service.id] = run.active || !cleaned ? "failed — \(run.status)" : "stopped"
    }
}
