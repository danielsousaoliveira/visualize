import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    private(set) var projects: [Project] = []
    var runningServices: [RunningService] = []
    private(set) var serviceRuns: [String: ServiceRun] = [:]
    var portConflict: PortConflict?
    private var resolvingPorts: Set<String> = []
    private var startingServices: Set<String> = []
    private var ownedGroups: Set<Int32> = []
    private var loginEnvironment = Task { try await LocalProcess.environment() }

    func runKey(project: Project, service: ScanService) -> String {
        "\(project.id.uuidString):\(service.id)"
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
            if let port = service.port {
                if !allowBusyPort, portConflict != nil {
                    reportDeferredStart(key: key, recipe: recipe)
                    return
                }
                let override = dockerOverridePath
                let owners = try await Task.detached { try PortOwnerLookup.owners(port: port, dockerOverridePath: override) }.value
                guard run.active, serviceRuns[key] === run else { return }
                if !allowBusyPort, !owners.isEmpty {
                    if portConflict != nil {
                        reportDeferredStart(key: key, recipe: recipe)
                        return
                    }
                    run.active = false
                    run.status = "Waiting for port conflict decision"
                    portConflict = PortConflict(project: project, service: service, recipe: recipe, environment: storedEnvironment, owners: owners)
                    return
                }
            }
            let recorded = RunRecipe(argv: recipe.argv, workingDirectory: recipe.workingDirectory, addedEnvironmentKeys: environment.keys.filter { ProcessInfo.processInfo.environment[$0] == nil }.sorted(), startedAt: Date())
            let actual = ServiceRun(recipe: recorded)
            serviceRuns[key] = actual
            let (pid, output) = try LocalProcess.start(recorded, environment: environment)
            ownedGroups.insert(pid)
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
                while true {
                    guard let data = try? output.read(upToCount: 65_536), !data.isEmpty else { break }
                    await actual.append(data)
                }
                try? output.close()
                while kill(-pid, 0) == 0 { try? await Task.sleep(for: .milliseconds(100)) }
                await self.releaseGroup(pid)
            }
            Task.detached {
                var status: Int32 = 0
                var exitInfo = siginfo_t()
                while waitid(P_PID, UInt32(pid), &exitInfo, WEXITED | WNOWAIT) == -1 && errno == EINTR {}
                if let group = await actual.group {
                    while group.exists { try? await Task.sleep(for: .milliseconds(100)) }
                }
                while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
                let code = status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
                await self.finished(actual, code: code, runningID: runningID)
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
                    let override = dockerOverridePath
                    let remaining = try await Task.detached { try PortOwnerLookup.owners(port: port, dockerOverridePath: override) }.value
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
        return !ownedGroups.isEmpty
    }

    func stop(project: Project, service: ScanService) async {
        guard let run = serviceRuns[runKey(project: project, service: service)] else { return }
        await stop(run)
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
        guard await stop(run) else { return }
        await start(project: project, service: service, recipe: recipe ?? run.recipe, storedEnvironment: run.launchEnvironment)
    }

    func stopForQuit() async {
        await withTaskGroup(of: Void.self) { group in
            for run in serviceRuns.values where run.active {
                group.addTask { await self.stop(run) }
            }
        }
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

    init(scanHelper: ScanHelper = .bundled(), store: ProjectLibraryStore = .applicationSupport()) {
        self.scanHelper = scanHelper
        self.store = store
        loadLibrary()
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
