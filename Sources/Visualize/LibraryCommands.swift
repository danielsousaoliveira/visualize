import SwiftUI

struct LibraryCommands: Commands {
    let appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Add project…", action: addProject)
                .keyboardShortcut("o")
            Button("Rescan", action: rescanSelection)
                .keyboardShortcut("r")
                .disabled(!canRescanSelection)
        }
    }

    private var canRescanSelection: Bool {
        guard let project = appState.selectedProject else { return false }
        return project.folderExists && !appState.isScanning(project.id)
    }

    private func addProject() {
        guard let folder = FolderPicker.choose(prompt: "Add") else { return }
        openWindow(id: MainWindow.id)
        Task { await appState.addProject(folder: folder) }
    }

    private func rescanSelection() {
        guard let id = appState.selection else { return }
        Task { await appState.rescan(id) }
    }
}
