import SwiftUI
import AppKit

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
        CommandGroup(after: .toolbar) {
            Toggle("Show coding agents", isOn: Binding(
                get: { appState.settings.showCodingAgents },
                set: { appState.settings.setShowCodingAgents($0) }
            ))
            Button("Check Docker status") { Task { await appState.checkDocker() } }
                .disabled(appState.isCheckingDocker)
        }
        CommandGroup(replacing: .help) {
            Button("visualize Help") {
                let alert = NSAlert()
                alert.messageText = "Using visualize"
                alert.informativeText = "Add a folder to discover its services and subfolders. Choose a run mode and start services, or open Graph to see their connections. Databases, warnings, and service logs appear below the services. Use View → Show coding agents to include coding agent listeners, or Check Docker status to refresh Docker availability. The menu bar widget shows listening ports and opens the main window."
                alert.runModal()
            }
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
