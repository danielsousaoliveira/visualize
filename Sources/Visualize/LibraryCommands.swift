import AppKit
import SwiftUI

struct ScanCommands: Commands {
    let appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Scan folder…", action: chooseFolder)
                .keyboardShortcut("o")
                .disabled(appState.isScanning)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        openWindow(id: MainWindow.id)
        appState.scan(folder: folder)
    }
}
