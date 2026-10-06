import Foundation

struct ProjectLibraryStore: Sendable {
    static let fileName = "library.json"
    static let currentVersion = 1

    private struct Library: Codable {
        var version: Int
        var projects: [Project]
    }

    let fileURL: URL

    init(directory: URL) {
        fileURL = directory.appending(path: Self.fileName)
    }

    static func applicationSupport(bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "visualize") -> ProjectLibraryStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ProjectLibraryStore(directory: base.appending(path: bundleIdentifier, directoryHint: .isDirectory))
    }

    func load() throws -> [Project] {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else { return [] }
        let library = try JSONDecoder().decode(Library.self, from: Data(contentsOf: fileURL))
        guard library.version == Self.currentVersion else {
            throw ProjectLibraryError.unsupportedVersion(library.version)
        }
        return library.projects
    }

    func save(_ projects: [Project]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Library(version: Self.currentVersion, projects: projects))
        try data.write(to: fileURL, options: .atomic)
    }

    func moveAside() throws -> URL {
        let stamp = Int(Date().timeIntervalSince1970)
        let destination = fileURL.deletingLastPathComponent().appending(path: "library.unreadable-\(stamp).json")
        try FileManager.default.moveItem(at: fileURL, to: destination)
        return destination
    }
}
