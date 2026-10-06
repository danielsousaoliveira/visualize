import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    private(set) var projects: [Project] = []
    var runningServices: [RunningService] = []
    var selection: Project.ID?
    var libraryError: String?
    private(set) var scanning: Set<Project.ID> = []
    private(set) var scanErrors: [Project.ID: String] = [:]

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
