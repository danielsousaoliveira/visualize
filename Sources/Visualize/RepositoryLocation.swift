import Foundation

struct RepositoryLocation {
    let root: String
    let originalRoot: String
    let branch: String?

    static func find(directory: String) -> Self? {
        var folder = URL(filePath: directory).standardizedFileURL.resolvingSymlinksInPath()
        while folder.path != "/" {
            let marker = folder.appending(path: ".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: marker.path, isDirectory: &isDirectory) {
                let gitDirectory: URL
                if isDirectory.boolValue {
                    gitDirectory = marker
                } else {
                    guard let value = read(marker), value.hasPrefix("gitdir: ") else { return nil }
                    gitDirectory = URL(filePath: String(value.dropFirst(8)), directoryHint: .isDirectory, relativeTo: folder)
                }
                let common = read(gitDirectory.appending(path: "commondir"))
                    .map { URL(filePath: $0, directoryHint: .isDirectory, relativeTo: gitDirectory).standardizedFileURL.resolvingSymlinksInPath() }
                    ?? gitDirectory
                let head = read(gitDirectory.appending(path: "HEAD"))
                let branch = head.flatMap { $0.hasPrefix("ref: refs/heads/") ? String($0.dropFirst(16)) : nil }
                return Self(root: Project.canonicalPath(of: folder), originalRoot: Project.canonicalPath(of: common.deletingLastPathComponent()), branch: branch)
            }
            folder.deleteLastPathComponent()
        }
        return nil
    }

    private static func read(_ url: URL) -> String? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 16_384,
              let value = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
