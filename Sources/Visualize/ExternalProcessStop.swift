import Darwin
import Foundation

struct ExternalProcessStop {
    static func identity(_ pid: Int32) -> ProcessIdentity? {
        var info = proc_bsdinfo()
        guard pid > 1, pid != getpid(),
              proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
              info.pbi_uid == getuid(), info.pbi_uid != 0 else { return nil }
        return ProcessIdentity(pid: pid, seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
    }

    static func stop(_ listener: ProcessListener) throws {
        guard let expected = listener.identity, identity(listener.pid) == expected,
              ProcessListenerMonitor().scan(ports: listener.port...listener.port, projects: []).contains(where: { $0.identity == expected }),
              identity(listener.pid) == expected else {
            throw NSError(domain: "Process identity or listening port changed; stop refused", code: 1)
        }
        if kill(listener.pid, SIGTERM) != 0, errno != ESRCH {
            throw NSError(domain: "Could not stop process", code: Int(errno))
        }
    }
}
