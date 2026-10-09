import SwiftUI
import AppKit

struct LibraryCommands: Commands {
    let appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Add project…", action: addProject).help("Add project…")
                .keyboardShortcut("o")
            Button("Rescan", action: rescanSelection).help("Rescan")
                .keyboardShortcut("r")
                .disabled(!canRescanSelection)
        }
        CommandGroup(after: .toolbar) {
            Button("Check Docker status") { Task { await appState.checkDocker() } }
                .disabled(appState.isCheckingDocker)
                .help("Refresh Docker availability")
        }
        CommandGroup(after: .windowList) {
            Button("Show visualize") {
                openWindow(id: MainWindow.id)
                NSApp.activate(ignoringOtherApps: true)
            }.help("Bring the main visualize window to the front")
        }
        CommandGroup(replacing: .help) {
            Button("visualize Help") {
                let alert = NSAlert()
                alert.messageText = "Using visualize"
                alert.informativeText = "Add a folder to discover its services and subfolders. Choose a run mode and start services, or open Graph to see their connections. Databases, warnings, and service logs appear below the services. Use View → Check Docker status to refresh Docker availability. The menu bar widget shows listening ports and opens the main window."
                alert.runModal()
            }.help("Show a guide to visualize")
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
