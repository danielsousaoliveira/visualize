import Foundation

struct DockerPath {
    static func resolve(_ path: String, project: Project) throws -> URL {
        let root = project.folderURL.standardizedFileURL.resolvingSymlinksInPath()
        let requested = project.folderURL.appending(path: path).standardizedFileURL
        guard FileManager.default.fileExists(atPath: requested.path) else {
            throw NSError(domain: "VisualizeDocker", code: 1, userInfo: [NSLocalizedDescriptionKey: "Docker path does not exist: \(path)"])
        }
        let candidate = requested.resolvingSymlinksInPath()
        guard !NSString(string: path).isAbsolutePath,
              candidate.path == root.path || candidate.path.hasPrefix(root.path + "/") else {
            throw NSError(domain: "VisualizeDocker", code: 1, userInfo: [NSLocalizedDescriptionKey: "Docker path outside project: \(path)"])
        }
        return candidate
    }
}
