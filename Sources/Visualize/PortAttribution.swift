import Foundation

struct PortAttribution {
    static func contains(_ root: String, _ path: String) -> Bool {
        path == root || path.hasPrefix(root == "/" ? root : root + "/")
    }

    static func resolve(_ listener: ProcessListener, projects: [Project], dockerOwnership: String? = nil) -> ProcessListener {
        var result = listener
        let directory = listener.workingDirectory.map { Project.canonicalPath(of: URL(filePath: $0)) }
        let repository = directory.flatMap { RepositoryLocation.find(directory: $0) }
        let attributionDirectory = directory.map { path in
            guard let repository else { return path }
            return repository.originalRoot + path.dropFirst(repository.root.count)
        }
        let container = listener.container
        let owned = container?.isOwned(by: dockerOwnership) == true
        let project = (owned ? projects.first { $0.id.uuidString == container?.labels["visualize.library"] } : nil)
            ?? (owned ? nil : directory.flatMap { path in projects.filter { contains($0.folderPath, path) }.max { $0.folderPath.count < $1.folderPath.count } })
            ?? (owned ? nil : attributionDirectory.flatMap { path in projects.filter { contains($0.folderPath, path) }.max { $0.folderPath.count < $1.folderPath.count } })
        result.libraryProjectID = project?.id
        result.startedByVisualize = owned
        result.projectName = project?.lastResult?.project.name ?? project?.name ?? container?.visualizeProject ?? container?.composeProject ?? listener.projectName
        result.gitBranch = repository?.branch ?? listener.gitBranch ?? project?.lastResult?.project.gitBranch
        result.repositoryRoot = repository?.root
        let services = project?.lastResult?.services ?? []
        if let container {
            let key = owned ? container.visualizeService : container.composeService
            let candidates = services.filter { $0.id == key || $0.runModes.compose.serviceName == key }
            let matched = candidates.first { service in
                guard let attributionDirectory, let project else { return false }
                let composeRoot = service.runModes.compose.composeFile.map { project.folderURL.appending(path: $0).deletingLastPathComponent().path }
                return composeRoot == attributionDirectory
            } ?? candidates.first
            result.serviceID = matched?.id
            result.serviceName = matched?.name ?? key
        } else if let project, let directory = attributionDirectory {
            let matched = services.filter { service in
                let root = serviceRoot(service, project: project)
                return contains(project.folderPath, root) && contains(root, directory)
            }.max { serviceRoot($0, project: project).count < serviceRoot($1, project: project).count }
            result.serviceID = matched?.id
            result.serviceName = matched?.name ?? repository.map { URL(filePath: $0.originalRoot).lastPathComponent }
        }
        return result
    }

    private static func serviceRoot(_ service: ScanService, project: Project) -> String {
        let root = NSString(string: service.rootDirectory).isAbsolutePath ? URL(filePath: service.rootDirectory) : project.folderURL.appending(path: service.rootDirectory)
        return Project.canonicalPath(of: root)
    }

    static func externalName(directory: String?) -> String? {
        guard let directory, !directory.isEmpty else { return nil }
        var folder = URL(filePath: directory)
        let repository = RepositoryLocation.find(directory: directory)
        while folder.path != "/" {
            for manifest in ["package.json", "composer.json"] {
                let url = folder.appending(path: manifest)
                if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_048_576,
                   let data = try? Data(contentsOf: url), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let name = object["name"] as? String, !name.isEmpty { return name }
            }
            if folder.path == repository?.root {
                return repository.map { URL(filePath: $0.originalRoot).lastPathComponent }
            }
            folder.deleteLastPathComponent()
        }
        return URL(filePath: directory).lastPathComponent
    }
}
