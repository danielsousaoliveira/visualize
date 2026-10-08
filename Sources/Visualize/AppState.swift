import Foundation
import CryptoKit
import Observation

@MainActor
@Observable
final class AppState {
    private(set) var projects: [Project] = []
    let listenerStore = ProcessListenerStore()
    var runningServices: [RunningService] = []
    private(set) var serviceLogs: [String: ServiceLog] = [:]
    private(set) var serviceRuns: [String: ServiceRun] = [:]
    private var launchedProjects: [UUID: Project] = [:]
    var launchedServices: [UUID: [String: ScanService]] = [:]
    var projectRunResults: [UUID: ScanResult] = [:]
    var projectOperations: [UUID: ProjectOperation] = [:]
    var portConflict: PortConflict?
    var portLookupError: String?
    private var resolvingPorts: Set<String> = []
    private var startingServices: Set<String> = []
    private var dockerProjects: Set<UUID> = []
    private var dockerStarts: [UUID: Int] = [:]
    let dockerOwnership: String
    private var ownedGroups: Set<Int32> = []
    private let outputDrainerURL: URL?
    private var loginEnvironment = Task { try await LocalProcess.environment() }

    func dockerOperationBusy(_ id: UUID) -> Bool { dockerProjects.contains(id) || dockerStarts[id, default: 0] > 0 }

    func runKey(project: Project, service: ScanService) -> String {
        "\(project.id.uuidString):\(service.id)"
    }

    func logs(project: Project, service: ScanService) -> ServiceLog {
        let key = runKey(project: project, service: service)
        if let log = serviceLogs[key] { return log }
        let root = store.fileURL.deletingLastPathComponent().appending(path: "Logs/\(project.id.uuidString)")
        let digest = SHA256.hash(data: Data(service.id.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let filename = "\(DockerRun.slug(service.name).prefix(40))-\(digest)"
        let log = ServiceLog(fileURL: root.appending(path: "\(filename).log"))
        serviceLogs[key] = log
        return log
    }

    func recipe(project: Project, service: ScanService) -> RunRecipe? {
        guard let command = service.devCommand, !command.argv.isEmpty else { return nil }
        return RunRecipe(argv: command.argv, workingDirectory: project.folderURL.appending(path: command.workingDirectory).standardizedFileURL.path, addedEnvironmentKeys: [], startedAt: Date())
    }

    func approved(_ recipe: RunRecipe, project: Project) -> Bool {
        (UserDefaults.standard.stringArray(forKey: "approvedCommands.\(project.id)") ?? []).contains(recipe.approvalKey)
    }

    func start(project: Project, service: ScanService, recipe: RunRecipe, storedEnvironment: [String: String]? = nil, allowBusyPort: Bool = false) async {
        let key = runKey(project: project, service: service)
        guard serviceRuns[key]?.active != true, !startingServices.contains(key), !resolvingPorts.contains(key) else { return }
        startingServices.insert(key)
        defer { startingServices.remove(key) }
        let run = ServiceRun(recipe: recipe)
        serviceRuns[key] = run
        do {
            let capture = loginEnvironment
            let environment: [String: String]
            do {
                if let storedEnvironment { environment = storedEnvironment }
                else { environment = try await capture.value }
            } catch {
                if loginEnvironment == capture {
                    loginEnvironment = Task { try await LocalProcess.environment() }
                }
                throw error
            }
            guard run.active, serviceRuns[key] === run else { return }
            guard try await checkAndResolvePortConflict(project: project, service: service, run: run, storedEnvironment: storedEnvironment, allowBusyPort: allowBusyPort) else { return }
            let recorded = RunRecipe(argv: recipe.argv, workingDirectory: recipe.workingDirectory, addedEnvironmentKeys: environment.keys.filter { ProcessInfo.processInfo.environment[$0] == nil }.sorted(), startedAt: Date())
            let actual = ServiceRun(recipe: recorded)
            serviceRuns[key] = actual
            let log = logs(project: project, service: service)
            actual.log = log
            let stderr = Pipe()
            let (pid, output) = try LocalProcess.start(recorded, environment: environment, outputDrainerURL: outputDrainerURL, stderr: stderr)
            ownedGroups.insert(pid)
            launchedProjects[project.id] = project
            launchedServices[project.id, default: [:]][service.id] = service
            actual.pid = pid
            actual.group = OwnedProcessGroup.capture(pid)
            actual.launchEnvironment = environment
            actual.status = "Running (pid \(pid))"
            let runningID = UUID()
            actual.runningID = runningID
            runningServices.append(RunningService(id: runningID, name: service.name))
            let approvalStore = "approvedCommands.\(project.id)"
            var approvals = UserDefaults.standard.stringArray(forKey: approvalStore) ?? []
            if !approvals.contains(recipe.approvalKey) { approvals.append(recipe.approvalKey) }
            UserDefaults.standard.set(approvals, forKey: approvalStore)
            Task.detached {
                await OrderedOutputReader.drain(stdout: output, stderr: stderr.fileHandleForReading) { data, isError in
                    if let data { actual.append(data, isError: isError) }
                    else { log.finish(isError: isError) }
                } failed: { message, isError in
                    log.reportReadFailure(message, isError: isError)
                }
                await actual.finishOutput()
                while kill(-pid, 0) == 0 { try? await Task.sleep(for: .milliseconds(100)) }
                await self.releaseGroup(pid)
            }
            Task.detached {
                var status: Int32 = 0
                await LocalProcess.waitForExit(pid)
                if let group = await actual.group {
                    while group.exists { try? await Task.sleep(for: .milliseconds(100)) }
                }
                while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
                let code = status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
                let outputDeadline = ContinuousClock.now.advanced(by: .seconds(1))
                while !(await actual.outputFinished), ContinuousClock.now < outputDeadline {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                await self.finished(actual, code: code, runningID: runningID)
                if code != 0, !allowBusyPort {
                    await self.recheckBindFailure(project: project, service: service, run: actual)
                }
            }
            if let port = service.port {
                Task {
                    while actual.active {
                        actual.portReady = await Task.detached { LocalProcess.listening(port: port, processGroup: pid) }.value
                        try? await Task.sleep(for: .seconds(1))
                    }
                    actual.portReady = false
                }
            }
        } catch {
            serviceRuns[key]?.active = false
            serviceRuns[key]?.status = "Failed: \(error.localizedDescription)"
        }
    }

    private func portOwners(_ port: Int) async throws -> [PortOwner] {
        let override = dockerOverridePath
        do {
            return try await Task.detached { try PortOwnerLookup.owners(port: port, dockerOverridePath: override) }.value
        } catch {
            portLookupError = error.localizedDescription
            throw error
        }
    }

    private func checkAndResolvePortConflict(project: Project, service: ScanService, run: ServiceRun, storedEnvironment: [String: String]?, allowBusyPort: Bool) async throws -> Bool {
        let key = runKey(project: project, service: service)
        guard let port = service.port else { return true }
        if !allowBusyPort, portConflict != nil {
            reportDeferredStart(key: key, recipe: run.recipe)
            return false
        }
        let owners = try await portOwners(port)
        guard run.active, serviceRuns[key] === run else { return false }
        guard !allowBusyPort, !owners.isEmpty else { return true }
        if portConflict != nil {
            reportDeferredStart(key: key, recipe: run.recipe)
            return false
        }
        run.active = false
        run.status = "Waiting for port conflict decision"
        portConflict = PortConflict(project: project, service: service, recipe: run.recipe, environment: storedEnvironment, owners: owners)
        return false
    }

    private func recheckBindFailure(project: Project, service: ScanService, run: ServiceRun) async {
        let key = runKey(project: project, service: service)
        guard let port = service.port, run.hasBindFailure, !run.stopping, serviceRuns[key] === run,
              !startingServices.contains(key), !resolvingPorts.contains(key) else { return }
        do {
            let owners = try await portOwners(port)
            guard serviceRuns[key] === run, !run.active, !run.stopping,
                  !startingServices.contains(key), !resolvingPorts.contains(key), !owners.isEmpty else { return }
            if portConflict != nil {
                run.status = "Port bind failed: resolve the open conflict, then press Play again"
                return
            }
            run.status = "Port bind failed; waiting for conflict decision"
            portConflict = PortConflict(project: project, service: service, recipe: run.recipe, environment: run.launchEnvironment, owners: owners)
        } catch {
            if serviceRuns[key] === run { run.status = "Port bind failed: \(error.localizedDescription)" }
        }
    }

    private func reportDeferredStart(key: String, recipe: RunRecipe) {
        let run = ServiceRun(recipe: recipe)
        run.active = false
        run.status = "Start not handled: resolve the open port conflict, then press Play again"
        serviceRuns[key] = run
    }

    func projectName(for owner: PortOwner) -> String? {
        guard let directory = owner.workingDirectory else { return nil }
        let path = Project.canonicalPath(of: URL(filePath: directory))
        return projects.sorted { $0.folderPath.count > $1.folderPath.count }.first {
            path == $0.folderPath || path.hasPrefix($0.folderPath + "/")
        }?.name
    }

    func ownedAttribution(_ listener: ProcessListener) -> ProcessListener? {
        guard let identity = listener.identity else { return nil }
        let owner = PortOwner(port: listener.port, pid: listener.pid, name: listener.name, uid: getuid(),
                              seconds: identity.seconds, microseconds: identity.microseconds, workingDirectory: listener.workingDirectory)
        guard let run = ownedRun(for: owner) else { return nil }
        for captured in launchedProjects.values {
            let project = projects.first { $0.id == captured.id } ?? captured
            for service in launchedServices[project.id, default: [:]].values where serviceRuns[runKey(project: project, service: service)] === run {
                var result = listener
                result.libraryProjectID = project.id
                result.projectName = project.lastResult?.project.name ?? project.name
                result.serviceName = service.name
                result.startedByVisualize = true
                return result
            }
        }
        return nil
    }

    func owns(_ owner: PortOwner) -> Bool {
        ownedRun(for: owner) != nil
    }

    private func ownedRun(for owner: PortOwner) -> ServiceRun? {
        serviceRuns.values.first { $0.active && $0.group?.contains(owner) == true }
    }

    func stopUnavailableReason(for owner: PortOwner) -> String? {
        if owns(owner) { return nil }
        if owner.containerID == nil, owner.uid != nil, owner.uid != getuid() || owner.uid == 0 {
            return "Owned by another user"
        }
        return "Not started by visualize"
    }

    func resolve(_ conflict: PortConflict, stopOwners: Bool) async {
        guard portConflict?.id == conflict.id else { return }
        let key = runKey(project: conflict.project, service: conflict.service)
        guard !resolvingPorts.contains(key) else { return }
        resolvingPorts.insert(key)
        defer { resolvingPorts.remove(key) }
        portConflict = nil
        do {
            if stopOwners {
                let runs = conflict.owners.compactMap { ownedRun(for: $0) }
                guard runs.count == conflict.owners.count else {
                    throw NSError(domain: "Port owner is not verified as started by visualize", code: 1)
                }
                for run in runs {
                    guard await stop(run) else { throw NSError(domain: "Could not stop owned service", code: 1) }
                }
                let deadline = ContinuousClock.now.advanced(by: .seconds(10))
                while true {
                    let port = conflict.owners[0].port
                    let remaining = try await portOwners(port)
                    if remaining.isEmpty { break }
                    guard ContinuousClock.now < deadline else { throw NSError(domain: "Port is still in use; service was not started", code: 1) }
                    try await Task.sleep(for: .milliseconds(200))
                }
            }
            resolvingPorts.remove(key)
            await start(project: conflict.project, service: conflict.service, recipe: conflict.recipe, storedEnvironment: conflict.environment, allowBusyPort: !stopOwners)
        } catch {
            let run = ServiceRun(recipe: conflict.recipe)
            run.active = false
            run.status = "Failed: \(error.localizedDescription)"
            serviceRuns[runKey(project: conflict.project, service: conflict.service)] = run
        }
    }

    private func releaseGroup(_ pid: Int32) { ownedGroups.remove(pid) }

    private func finished(_ run: ServiceRun, code: Int32, runningID: UUID) {
        run.leaderReaped = true
        run.active = false
        if !run.stopping { run.status = "Exited (\(code))" }
        run.portReady = false
        runningServices.removeAll { $0.id == runningID }
    }

    var hasOwnedProcesses: Bool {
        ownedGroups = ownedGroups.filter { kill(-$0, 0) == 0 }
        return !ownedGroups.isEmpty || serviceRuns.values.contains { ($0.docker != nil && $0.active) || $0.busy }
    }

    func stop(project: Project, service: ScanService) async {
        guard let run = serviceRuns[runKey(project: project, service: service)] else { return }
        if run.docker != nil {
            guard !dockerProjects.contains(project.id) else { return }
            dockerProjects.insert(project.id)
            defer { dockerProjects.remove(project.id) }
            await stopDocker(run)
        }
        else { await stop(run) }
    }

    @discardableResult
    private func stop(_ run: ServiceRun) async -> Bool {
        if run.stopping {
            while run.stopping { try? await Task.sleep(for: .milliseconds(50)) }
            return !run.active
        }
        guard run.active else { return true }
        run.stopping = true
        run.status = "Stopping…"
        defer { run.stopping = false }
        guard let group = run.group else {
            run.status = "Stop failed: process-group identity unavailable"
            return false
        }
        let stopped = await Task.detached { await group.stop() }.value
        guard stopped || group.confirmedGone else {
            run.active = true
            run.status = "Stop failed: could not safely signal the process group"
            return false
        }
        if stopped {
            while !run.leaderReaped { try? await Task.sleep(for: .milliseconds(50)) }
        }
        ownedGroups.remove(group.pid)
        if let id = run.runningID { runningServices.removeAll { $0.id == id } }
        run.active = false
        run.portReady = false
        run.status = "Exited"
        return true
    }

    func restart(project: Project, service: ScanService, recipe: RunRecipe? = nil) async {
        guard let run = serviceRuns[runKey(project: project, service: service)], !run.stopping else { return }
        if run.docker != nil {
            await restartDocker(project: project, service: service, run: run)
            return
        }
        guard await stop(run) else { return }
        await start(project: project, service: service, recipe: recipe ?? run.recipe, storedEnvironment: run.launchEnvironment)
    }

    @discardableResult
    func stopForQuit() async -> Bool {
        while !dockerProjects.isEmpty || !dockerStarts.isEmpty || projectOperations.values.contains(where: { $0.busy }) || serviceRuns.values.contains(where: { $0.busy || $0.stopping }) {
            try? await Task.sleep(for: .milliseconds(50))
        }
        let runs = Array(serviceRuns.values.filter { $0.active })
        let projectIDs = Set(runs.compactMap { $0.docker?.projectID })
        dockerProjects.formUnion(projectIDs)
        defer { dockerProjects.subtract(projectIDs) }
        var stopped = true
        for run in runs {
            let success: Bool
            if run.docker != nil { success = await stopDocker(run) }
            else { success = await stop(run) }
            if !success { stopped = false }
        }
        return stopped
    }
    var selection: Project.ID?
    var libraryError: String?
    private(set) var scanning: Set<Project.ID> = []
    private(set) var scanErrors: [Project.ID: String] = [:]

    private(set) var dockerState: DockerState = .checking
    private(set) var isCheckingDocker = false
    var dockerOverridePath: String? {
        get { UserDefaults.standard.string(forKey: "dockerOverridePath") }
        set { UserDefaults.standard.set(newValue, forKey: "dockerOverridePath") }
    }

    func checkDocker() async {
        guard !isCheckingDocker else { return }
        isCheckingDocker = true
        dockerState = .checking
        defer { isCheckingDocker = false }
        dockerState = await DockerChecker().check(overridePath: dockerOverridePath)
    }

    private let scanHelper: ScanHelper
    private let store: ProjectLibraryStore
    private var canSave = true

    init(scanHelper: ScanHelper = .bundled(), store: ProjectLibraryStore = .applicationSupport(), dockerOwnership: String? = nil, outputDrainerURL: URL? = nil) {
        self.outputDrainerURL = outputDrainerURL
        if let dockerOwnership { self.dockerOwnership = dockerOwnership }
        else if let saved = UserDefaults.standard.string(forKey: "dockerOwnership"), UUID(uuidString: saved) != nil { self.dockerOwnership = saved }
        else {
            let token = UUID().uuidString
            UserDefaults.standard.set(token, forKey: "dockerOwnership")
            self.dockerOwnership = token
        }
        self.scanHelper = scanHelper
        self.store = store
        loadLibrary()
        listenerStore.start(dockerOwnership: self.dockerOwnership, projects: { [weak self] in self?.projects ?? [] }, ownedAttribution: { [weak self] in self?.ownedAttribution($0) }, dockerOverride: { [weak self] in self?.dockerOverridePath })
    }

    var selectedProject: Project? {
        selection.flatMap(project)
    }

    func project(_ id: Project.ID) -> Project? {
        projects.first { $0.id == id }
    }

    func isScanning(_ id: Project.ID) -> Bool {
        scanning.contains(id)
    }

    func addProject(folder: URL) async {
        let path = Project.canonicalPath(of: folder)
        if let existing = projects.first(where: { $0.folderPath == path }) {
            selection = existing.id
            return
        }
        let project = Project(folder: folder)
        projects.append(project)
        selection = project.id
        persist()
        await rescan(project.id)
    }

    func rescan(_ id: Project.ID) async {
        guard let project = project(id), !scanning.contains(id) else { return }
        scanning.insert(id)
        defer { scanning.remove(id) }
        do {
            let result = try await scanHelper.scan(folder: project.folderURL)
            guard let index = projects.firstIndex(where: { $0.id == id }),
                  projects[index].folderPath == project.folderPath else { return }
            projects[index].lastResult = result
            scanErrors[id] = nil
            persist()
        } catch {
            guard self.project(id)?.folderPath == project.folderPath else { return }
            scanErrors[id] = error.localizedDescription
        }
    }

    func scanProjectsWithoutResults() async {
        let pending = projects.filter { $0.lastResult == nil && $0.folderExists }.map(\.id)
        await withTaskGroup(of: Void.self) { group in
            for id in pending {
                group.addTask { await self.rescan(id) }
            }
        }
    }

    func locate(_ id: Project.ID, at folder: URL) async {
        let path = Project.canonicalPath(of: folder)
        if let other = projects.first(where: { $0.folderPath == path && $0.id != id }) {
            selection = other.id
            return
        }
        guard let index = projects.firstIndex(where: { $0.id == id }), !scanning.contains(id) else { return }
        projects[index].move(to: folder)
        scanErrors[id] = nil
        persist()
        await rescan(id)
    }

    func remove(_ id: Project.ID) {
        projects.removeAll { $0.id == id }
        scanErrors[id] = nil
        if selection == id {
            selection = nil
        }
        persist()
    }

    private func loadLibrary() {
        do {
            projects = try store.load()
        } catch {
            let reason = error.localizedDescription
            do {
                let backup = try store.moveAside()
                libraryError = "The project library could not be read (\(reason)). It was moved to \(backup.path(percentEncoded: false)) and visualize started with an empty library."
            } catch {
                canSave = false
                libraryError = "The project library could not be read (\(reason)). Changes will not be saved until \(store.fileURL.path(percentEncoded: false)) is fixed or removed."
            }
        }
    }

    private func persist() {
        guard canSave else { return }
        do {
            try store.save(projects)
        } catch {
            libraryError = "The project library could not be saved: \(error.localizedDescription)"
        }
    }
}

extension AppState {
    func mode(project: Project, service: ScanService) -> ServiceMode {
        if let run = serviceRuns[runKey(project: project, service: service)], run.active, let docker = run.docker { return docker.mode }
        let available = ServiceMode.available(for: service)
        if let value = UserDefaults.standard.string(forKey: "serviceMode.\(runKey(project: project, service: service))"),
           let mode = ServiceMode(rawValue: value), available.contains(mode) { return mode }
        return available.contains(.local) ? .local : available.first ?? .local
    }

    func setMode(_ mode: ServiceMode, project: Project, service: ScanService) {
        UserDefaults.standard.set(mode.rawValue, forKey: "serviceMode.\(runKey(project: project, service: service))")
    }

    func dockerReason(project: Project, service: ScanService) -> String? {
        let selected = mode(project: project, service: service)
        return selected == .local ? nil : dockerState.unavailableReason(compose: selected == .compose)
    }

    func startDocker(project: Project, service: ScanService, selectedMode: ServiceMode? = nil, composeServices: [ScanService]? = nil, parallel: Bool = false) async {
        let key = runKey(project: project, service: service)
        let selected = selectedMode ?? mode(project: project, service: service)
        guard selected != .local, dockerState.unavailableReason(compose: selected == .compose) == nil,
              serviceRuns[key]?.active != true, !dockerProjects.contains(project.id),
              parallel || !dockerOperationBusy(project.id) else { return }
        launchedProjects[project.id] = project
        launchedServices[project.id, default: [:]][service.id] = service
        dockerStarts[project.id, default: 0] += 1
        defer {
            dockerStarts[project.id, default: 0] -= 1
            if dockerStarts[project.id] == 0 { dockerStarts[project.id] = nil }
        }
        let run = ServiceRun(recipe: RunRecipe(argv: [], workingDirectory: project.folderPath, addedEnvironmentKeys: [], startedAt: Date()))
        run.busy = true
        serviceRuns[key] = run
        defer { run.busy = false }
        do {
            let override = dockerOverridePath
            let command = try await Task.detached { try DockerCommand.connect(overridePath: override) }.value
            let slug = DockerRun.projectSlug(project)
            if selected == .compose {
                guard let file = service.runModes.compose.composeFile, let name = service.runModes.compose.serviceName else { throw dockerError("Compose metadata missing; rescan") }
                let composeURL = try DockerPath.resolve(file, project: project)
                let base = ["compose", "-p", slug, "-f", composeURL.path]
                let existing = try await command.run(base + ["ps", "-a", "-q"], directory: project.folderPath)
                let ids = String(decoding: existing, as: UTF8.self).split(whereSeparator: \.isWhitespace).map(String.init)
                try await verifyDockerOwnership(ids, command: command, directory: project.folderPath, projectID: project.id)
                let services = project.lastResult?.services ?? [service]
                let entries = services.compactMap { item -> (String, [String: Any])? in
                    guard item.runModes.compose.composeFile == file, let name = item.runModes.compose.serviceName else { return nil }
                    return (name, ["labels": ["visualize.project": slug, "visualize.service": item.id, "visualize.owner": dockerOwnership, "visualize.library": project.id.uuidString]])
                }
                let overrideURL = FileManager.default.temporaryDirectory.appending(path: "visualize-compose-\(UUID().uuidString).json")
                try JSONSerialization.data(withJSONObject: ["services": Dictionary(entries, uniquingKeysWith: { first, _ in first })]).write(to: overrideURL, options: .atomic)
                defer { try? FileManager.default.removeItem(at: overrideURL) }
                run.docker = DockerRun(command: command, mode: selected, projectID: project.id, projectSlug: slug, serviceName: name, composeArguments: base, containerIDs: [])
                _ = try await command.run(base + ["-f", overrideURL.path, "up", "-d"] + (composeServices.map { ["--no-deps", "--no-recreate"] + $0.compactMap { $0.runModes.compose.serviceName } } ?? [name]), directory: project.folderPath) { run.append($0) }
                try await refreshCompose(project: project, source: run)
            } else {
                guard let path = service.runModes.dockerfile.dockerfilePath,
                      let host = service.port, let container = service.runModes.dockerfile.containerPort,
                      (1...65535).contains(host), (1...65535).contains(container) else { throw dockerError("Dockerfile requires detected host and container ports; rescan") }
                let dockerfileURL = try DockerPath.resolve(path, project: project)
                let contextURL = try DockerPath.resolve(service.rootDirectory, project: project)
                let serviceSlug = DockerRun.slug(service.id)
                let image = "visualize/\(slug)-\(serviceSlug):dev"
                let name = "visualize-\(slug)-\(serviceSlug)"
                let existing = try await command.run(["ps", "-a", "--no-trunc", "--filter", "name=^/\(name)$", "--format", "{{.ID}}"], directory: project.folderPath)
                let ids = String(decoding: existing, as: UTF8.self).split(whereSeparator: \.isWhitespace).map(String.init)
                if !ids.isEmpty {
                    do {
                        try await verifyDockerOwnership(ids, command: command, directory: project.folderPath, projectID: project.id)
                        for id in ids {
                            let label = try await command.run(["inspect", "--format", "{{index .Config.Labels \"visualize.service\"}}", id], directory: project.folderPath)
                            guard String(decoding: label, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == service.id else { throw dockerError("Service label does not match") }
                        }
                    } catch { throw dockerError("Container name \(name) is already in use by a container visualize cannot manage") }
                    run.docker = DockerRun(command: command, mode: selected, projectID: project.id, projectSlug: slug, serviceName: name, composeArguments: [], containerIDs: ids)
                    let running = try await command.run(["inspect", "--format", "{{.State.Running}}", ids[0]], directory: project.folderPath)
                    if String(decoding: running, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "true" {
                        markDockerRunning(run, name: service.name)
                        monitorDocker(project: project, run: run)
                        return
                    }
                    for id in ids { _ = try await command.run(["rm", id], directory: project.folderPath) { run.append($0) } }
                    run.docker = nil
                }
                _ = try await command.run(["build", "-t", image, "-f", dockerfileURL.path, contextURL.path], directory: project.folderPath) { run.append($0) }
                let data = try await command.run(["run", "-d", "--name", name, "--label", "visualize.project=\(slug)", "--label", "visualize.service=\(service.id)", "--label", "visualize.owner=\(dockerOwnership)", "--label", "visualize.library=\(project.id.uuidString)", "-p", "127.0.0.1:\(host):\(container)", image], directory: project.folderPath) { run.append($0) }
                let id = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
                guard !id.isEmpty else { throw dockerError("Docker did not return a container ID") }
                run.docker = DockerRun(command: command, mode: selected, projectID: project.id, projectSlug: slug, serviceName: name, composeArguments: [], containerIDs: [id])
                markDockerRunning(run, name: service.name)
            }
            if run.docker?.mode == .compose {
                for candidate in serviceRuns.values where candidate.docker?.projectID == project.id && candidate.active {
                    monitorDocker(project: project, run: candidate)
                }
            } else { monitorDocker(project: project, run: run) }
        } catch {
            if run.docker?.mode == .compose { try? await refreshCompose(project: project, source: run) }
            run.active = false
            run.status = "Failed: \(error.localizedDescription)"
            run.portReady = false
        }
    }

    private func dockerError(_ message: String) -> NSError {
        NSError(domain: "VisualizeDocker", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func verifyComposeService(_ docker: DockerRun, directory: String) async throws {
        let data = try await docker.command.run(docker.composeArguments + ["ps", "-a", "-q", docker.serviceName], directory: directory)
        let ids = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !ids.isEmpty else { throw dockerError("Compose container no longer exists") }
        try await verifyDockerOwnership(ids, command: docker.command, directory: directory, projectID: docker.projectID)
    }

    private func verifyDockerOwnership(_ ids: [String], command: DockerCommand, directory: String, projectID: UUID) async throws {
        for id in ids {
            let data = try await command.run(["inspect", "--format", "{{index .Config.Labels \"visualize.owner\"}} {{index .Config.Labels \"visualize.library\"}}", id], directory: directory)
            guard String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "\(dockerOwnership) \(projectID.uuidString)" else {
                throw dockerError("Container ownership does not match this visualize installation and project; Docker action refused")
            }
        }
    }

    func removeStoppedContainers(_ run: ServiceRun) async -> Bool {
        guard let docker = run.docker, !run.active, docker.mode == .compose else { return !run.active }
        guard !docker.containerIDs.isEmpty else { return false }
        do {
            try await verifyDockerOwnership(docker.containerIDs, command: docker.command, directory: run.recipe.workingDirectory, projectID: docker.projectID)
            for id in docker.containerIDs {
                _ = try await docker.command.run(["rm", id], directory: run.recipe.workingDirectory) { run.append($0) }
            }
            run.docker = nil
            return true
        } catch {
            run.status = "Cleanup failed: \(error.localizedDescription)"
            return false
        }
    }

    private func markDockerRunning(_ run: ServiceRun, name: String) {
        run.active = true
        run.status = "Running in Docker"
        run.portReady = true
        if run.runningID == nil {
            let id = UUID()
            run.runningID = id
            runningServices.append(RunningService(id: id, name: name))
        }
    }

    private func refreshCompose(project: Project, source: ServiceRun) async throws {
        guard let docker = source.docker else { return }
        let data = try await docker.command.run(["ps", "--no-trunc", "--filter", "label=com.docker.compose.project=\(docker.projectSlug)", "--filter", "label=visualize.owner=\(dockerOwnership)", "--filter", "label=visualize.library=\(project.id.uuidString)", "--format", "{{.ID}}\t{{.Label \"com.docker.compose.service\"}}"], directory: project.folderPath)
        if dockerOperationBusy(project.id), !source.busy { return }
        let rows = String(decoding: data, as: UTF8.self).split(separator: "\n").map { $0.split(separator: "\t").map(String.init) }
        for service in project.lastResult?.services ?? [] where service.runModes.compose.composeFile.flatMap({ try? DockerPath.resolve($0, project: project).path }).map({ docker.composeArguments.contains($0) }) == true {
            guard let name = service.runModes.compose.serviceName else { continue }
            let ids = rows.filter { $0.count == 2 && $0[1] == name }.map { $0[0] }
            let key = runKey(project: project, service: service)
            if ids.isEmpty {
                if let run = serviceRuns[key], run.docker?.mode == .compose, !run.busy, !run.stopping {
                    run.active = false
                    run.portReady = false
                    run.status = "Stopped"
                    if let id = run.runningID { runningServices.removeAll { $0.id == id }; run.runningID = nil }
                }
                continue
            }
            if serviceRuns[key]?.active == true && serviceRuns[key]?.docker == nil { continue }
            let run = serviceRuns[key] ?? ServiceRun(recipe: source.recipe)
            run.docker = DockerRun(command: docker.command, mode: .compose, projectID: project.id, projectSlug: docker.projectSlug, serviceName: name, composeArguments: docker.composeArguments, containerIDs: ids)
            serviceRuns[key] = run
            launchedProjects[project.id] = project
            launchedServices[project.id, default: [:]][service.id] = service
            markDockerRunning(run, name: service.name)
        }
        if source.busy, !rows.contains(where: { $0.count == 2 && $0[1] == docker.serviceName }) { throw dockerError("Compose service did not stay running") }
    }

    @discardableResult
    func stopDocker(_ run: ServiceRun) async -> Bool {
        guard let docker = run.docker, !run.busy, !run.stopping else { return false }
        if !run.active && docker.mode == .dockerfile { return true }
        run.stopping = true
        defer { run.stopping = false }
        do {
            guard !docker.containerIDs.isEmpty else { throw dockerError("Container identity unavailable; Docker action refused") }
            try await verifyDockerOwnership(docker.containerIDs, command: docker.command, directory: run.recipe.workingDirectory, projectID: docker.projectID)
            if docker.mode == .compose {
                try await verifyComposeService(docker, directory: run.recipe.workingDirectory)
                _ = try await docker.command.run(docker.composeArguments + ["stop", docker.serviceName], directory: run.recipe.workingDirectory) { run.append($0) }
            } else {
                for id in docker.containerIDs {
                    _ = try await docker.command.run(["stop", id], directory: run.recipe.workingDirectory) { run.append($0) }
                    _ = try await docker.command.run(["rm", id], directory: run.recipe.workingDirectory) { run.append($0) }
                }
            }
            run.active = false
            run.portReady = false
            run.status = "Stopped"
            if let id = run.runningID { runningServices.removeAll { $0.id == id }; run.runningID = nil }
            return true
        } catch {
            run.status = "Stop failed: \(error.localizedDescription)"
            return false
        }
    }

    func restartDocker(project: Project, service: ScanService, run: ServiceRun) async {
        guard let docker = run.docker, !run.busy, !run.stopping, !dockerProjects.contains(project.id),
              dockerState.unavailableReason(compose: docker.mode == .compose) == nil else { return }
        if docker.mode == .dockerfile {
            guard await stopDocker(run) else { return }
            setMode(.dockerfile, project: project, service: service)
            await startDocker(project: project, service: service)
            return
        }
        dockerProjects.insert(project.id)
        run.busy = true
        defer { run.busy = false; dockerProjects.remove(project.id) }
        do {
            guard !docker.containerIDs.isEmpty else { throw dockerError("Container identity unavailable; Docker action refused") }
            try await verifyDockerOwnership(docker.containerIDs, command: docker.command, directory: project.folderPath, projectID: docker.projectID)
            try await verifyComposeService(docker, directory: project.folderPath)
            _ = try await docker.command.run(docker.composeArguments + ["restart", docker.serviceName], directory: project.folderPath) { run.append($0) }
            try await refreshCompose(project: project, source: run)
            markDockerRunning(run, name: service.name)
            monitorDocker(project: project, run: run)
        } catch { run.status = "Failed: \(error.localizedDescription)" }
    }

    private func monitorDocker(project: Project, run: ServiceRun) {
        guard !run.monitoringDocker else { return }
        run.monitoringDocker = true
        Task {
            defer { run.monitoringDocker = false }
            while run.active {
                try? await Task.sleep(for: .seconds(2))
                guard run.active, !run.busy, !run.stopping, !dockerOperationBusy(project.id), let docker = run.docker, !docker.containerIDs.isEmpty else { continue }
                do {
                    if docker.mode == .compose { try await refreshCompose(project: project, source: run) }
                    else {
                        let data = try await docker.command.run(["ps", "--no-trunc", "--filter", "id=\(docker.containerIDs[0])", "--format", "{{.ID}}"], directory: project.folderPath)
                        if data.isEmpty {
                            run.active = false
                            run.portReady = false
                            run.status = "Stopped"
                            if let id = run.runningID { runningServices.removeAll { $0.id == id }; run.runningID = nil }
                        }
                    }
                } catch { run.status = "Docker status unavailable: \(error.localizedDescription)" }
            }
        }
    }
}

extension AppState {
    private func widgetService(_ listener: ProcessListener) -> (Project, ScanService)? {
        guard listener.startedByVisualize, listener.container == nil, let attributed = ownedAttribution(listener),
              let id = attributed.libraryProjectID, let project = projects.first(where: { $0.id == id }) ?? launchedProjects[id],
              let service = launchedServices[id]?.values.first(where: { $0.name == attributed.serviceName }) else { return nil }
        return (project, service)
    }

    func widgetRestartAvailable(_ listener: ProcessListener) -> Bool {
        listener.container != nil || widgetService(listener) != nil
    }

    func widgetAction(_ listener: ProcessListener, restart: Bool = false) async {
        guard listenerStore.listeners.contains(where: { $0.id == listener.id }) else { return }
        if let container = listener.container {
            await listenerStore.perform(restart ? "restart" : "stop", container: container, overridePath: dockerOverridePath, allowExternalRestart: true)
        } else if let (project, service) = widgetService(listener) {
            if restart { await self.restart(project: project, service: service) }
            else { await stop(project: project, service: service) }
        } else if !restart && !listener.startedByVisualize {
            do { try await Task.detached { try ExternalProcessStop.stop(listener) }.value }
            catch { portLookupError = error.localizedDescription }
        }
    }

    func widgetStopManagedAvailable(_ group: ProcessListenerGroup) -> Bool {
        if let id = group.listeners.first?.libraryProjectID,
           launchedServices[id, default: [:]].values.contains(where: { service in
               serviceRuns["\(id.uuidString):\(service.id)"].map { $0.active && $0.docker == nil } == true
           }) { return true }
        let ids = Set(group.listeners.map(\.id))
        return listenerStore.listeners.contains { ids.contains($0.id) && ($0.container != nil || widgetService($0) != nil) }
    }

    func widgetStopManaged(_ group: ProcessListenerGroup) async {
        if let id = group.listeners.first?.libraryProjectID,
           let project = projects.first(where: { $0.id == id }) ?? launchedProjects[id] {
            for service in launchedServices[id, default: [:]].values {
                let key = runKey(project: project, service: service)
                if serviceRuns[key]?.active == true, serviceRuns[key]?.docker == nil {
                    await stop(project: project, service: service)
                }
            }
        }
        var stopped: Set<String> = []
        for listener in group.listeners where listener.container != nil || listener.startedByVisualize {
            let key = listener.container?.id ?? "process:\(listener.pid)"
            guard stopped.insert(key).inserted else { continue }
            await widgetAction(listener)
        }
    }
}
