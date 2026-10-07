import Foundation
import Darwin

struct PortOwner: Identifiable, Sendable {
    let port: Int
    let pid: Int32
    let name: String
    let uid: UInt32?
    let seconds: UInt64?
    let microseconds: UInt64?
    let workingDirectory: String?
    var containerID: String?
    var containerName: String?
    var composeProject: String?
    var dockerPath: String?
    var dockerEndpoint: String?

    var id: String { "\(port):\(pid):\(containerID ?? "")" }
    var canStop: Bool { containerID != nil || (pid > 1 && pid != getpid() && uid == getuid() && uid != 0 && seconds != nil) }
    var title: String {
        if let containerName { return "Port \(port) is in use by container \(containerName)" }
        return "Port \(port) is in use by \(name) (pid \(pid))"
    }

    func terminate() throws {
        var info = proc_bsdinfo()
        guard canStop, containerID == nil,
              proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
              info.pbi_uid == getuid(), info.pbi_uid != 0,
              info.pbi_start_tvsec == seconds, info.pbi_start_tvusec == microseconds else {
            throw NSError(domain: "Port owner changed or cannot be safely stopped", code: 1)
        }
        guard kill(pid, SIGTERM) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
}
