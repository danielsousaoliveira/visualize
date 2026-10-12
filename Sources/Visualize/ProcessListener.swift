import Foundation

struct ProcessListener: Identifiable, Sendable {
    let port: Int
    let pid: Int32
    let name: String
    let executablePath: String?
    let workingDirectory: String?
    let startedAt: ProcessIdentity?
    let cpuPercent: Double?
    let memoryBytes: UInt64?
    var projectName: String?
    let projectFolder: String?
    var gitBranch: String?

    var libraryProjectID: UUID? = nil
    var repositoryRoot: String? = nil
    var serviceName: String? = nil
    var serviceID: String? = nil
    var startedByVisualize = false
    var attributionLabel: String {
        if libraryProjectID != nil || startedByVisualize {
            return "\(projectName ?? "Unknown project") / \(serviceName ?? "unknown service")"
        }
        return container.map { $0.composeProject ?? $0.name } ?? "\(projectName ?? "Unknown project") / \(name)"
    }
    var attributionGroup: String { libraryProjectID == nil && !startedByVisualize && repositoryRoot == nil ? "Other" : projectName ?? "Unknown project" }

    var container: DockerContainer? = nil

    var id: String {
        if let container { return "docker:\(container.id):\(port)" }
        return "\(port):\(pid):\(startedAt?.seconds ?? 0):\(startedAt?.microseconds ?? 0)"
    }
    var identity: ProcessIdentity? { startedAt }
    var processExplanation: String {
        if workingDirectory?.contains("/listener-project-") == true { return "Listener test fixture" }
        if workingDirectory?.contains("/.gradle/daemon/") == true { return "Java build worker" }
        if workingDirectory?.contains("/kotlin/daemon") == true { return "Kotlin build worker" }
        return executablePath.map { URL(filePath: $0).lastPathComponent } ?? name
    }
}

struct ProcessIdentity: Hashable, Sendable {
    let pid: Int32
    let seconds: UInt64
    let microseconds: UInt64
}
