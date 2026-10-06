import AppKit

@MainActor
enum FolderPicker {
    static func choose(prompt: String, startingAt directory: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        panel.directoryURL = directory
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
