import Foundation

struct Project: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String
    var folderPath: String
    var lastResult: ScanResult?

    init(id: UUID = UUID(), folder: URL, lastResult: ScanResult? = nil) {
        self.id = id
        self.name = folder.lastPathComponent
        self.folderPath = Self.canonicalPath(of: folder)
        self.lastResult = lastResult
    }

    var folderURL: URL {
        URL(filePath: folderPath, directoryHint: .isDirectory)
    }

    var folderExists: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: folderPath, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    mutating func move(to folder: URL) {
        name = folder.lastPathComponent
        folderPath = Self.canonicalPath(of: folder)
    }

    static func canonicalPath(of folder: URL) -> String {
        let path = folder.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
