import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    private(set) var projects: [Project] = []
    var runningServices: [RunningService] = []
    private(set) var serviceRuns: [String: ServiceRun] = [:]
    private var ownedGroups: Set<Int32> = []
    private let loginEnvironment = Task { try await LocalProcess.environment() }

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

    func start(project: Project, service: ScanService, recipe: RunRecipe) async {
        let key = runKey(project: project, service: service)
        guard serviceRuns[key]?.active != true else { return }
        let run = ServiceRun(recipe: recipe)
        serviceRuns[key] = run
        do {
            let environment = try await loginEnvironment.value
            let recorded = RunRecipe(argv: recipe.argv, workingDirectory: recipe.workingDirectory, addedEnvironmentKeys: environment.keys.filter { ProcessInfo.processInfo.environment[$0] == nil }.sorted(), startedAt: Date())
            let actual = ServiceRun(recipe: recorded)
            serviceRuns[key] = actual
            let (pid, output) = try LocalProcess.start(recorded, environment: environment)
            ownedGroups.insert(pid)
            actual.pid = pid
            actual.status = "Running (pid \(pid))"
            let runningID = UUID()
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

    private func releaseGroup(_ pid: Int32) { ownedGroups.remove(pid) }

    private func finished(_ run: ServiceRun, code: Int32, runningID: UUID) {
        run.active = false
        run.status = "Exited (\(code))"
        run.portReady = false
        runningServices.removeAll { $0.id == runningID }
    }

    var hasOwnedProcesses: Bool {
        ownedGroups = ownedGroups.filter { kill(-$0, 0) == 0 }
        return !ownedGroups.isEmpty
    }

    func stopForQuit() async {
        let groups = ownedGroups.filter { kill(-$0, 0) == 0 }
        for pid in groups { kill(-pid, SIGTERM) }
        try? await Task.sleep(for: .seconds(2))
        for pid in groups where kill(-pid, 0) == 0 { kill(-pid, SIGKILL) }
        let deadline = Date().addingTimeInterval(2)
        while groups.contains(where: { kill(-$0, 0) == 0 }) && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
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
