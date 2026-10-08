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
    let projectName: String?
    let projectFolder: String?
    let gitBranch: String?

    var id: String { "\(port):\(pid):\(startedAt?.seconds ?? 0):\(startedAt?.microseconds ?? 0)" }
    var identity: ProcessIdentity? { startedAt }
}

struct ProcessIdentity: Hashable, Sendable {
    let pid: Int32
    let seconds: UInt64
    let microseconds: UInt64
}
