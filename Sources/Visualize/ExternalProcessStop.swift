import Darwin
import Foundation

struct ExternalProcessStop {
    static func identity(_ pid: Int32) -> (ProcessIdentity, Int32)? {
        var info = proc_bsdinfo()
        guard pid > 1, pid != getpid(),
              proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
              info.pbi_uid == getuid(), info.pbi_uid != 0 else { return nil }
        return (ProcessIdentity(pid: pid, seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec), Int32(info.pbi_ppid))
    }

    static func stop(_ listener: ProcessListener) throws {
        guard let expected = listener.identity, identity(listener.pid)?.0 == expected,
              ProcessListenerMonitor().scan(ports: listener.port...listener.port, projects: []).contains(where: { $0.identity == expected }) else {
            throw NSError(domain: "Process identity changed; stop refused", code: 1)
        }
        var pids = [Int32](repeating: 0, count: 131_072)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        var members: [Int32: (ProcessIdentity, Int32)] = [:]
        for pid in pids.prefix(max(0, min(Int(count), pids.count))) {
            if let record = identity(pid) { members[pid] = record }
        }
        var tree: Set<Int32> = [listener.pid]
        var ordered = [expected]
        var changed = true
        while changed {
            changed = false
            for (pid, record) in members where tree.contains(record.1) && !tree.contains(pid) {
                tree.insert(pid)
                ordered.append(record.0)
                changed = true
            }
        }
        guard identity(listener.pid)?.0 == expected else {
            throw NSError(domain: "Process identity changed; stop refused", code: 1)
        }
        for member in ordered.reversed() {
            guard identity(member.pid)?.0 == member else { continue }
            if member.pid != listener.pid {
                var ancestor = member.pid
                var visited: Set<Int32> = []
                while ancestor != listener.pid, visited.insert(ancestor).inserted,
                      let captured = members[ancestor], let current = identity(ancestor), current == captured {
                    ancestor = current.1
                }
                guard ancestor == listener.pid, identity(listener.pid)?.0 == expected else { continue }
            }
            if kill(member.pid, SIGTERM) != 0, errno != ESRCH {
                throw NSError(domain: "Could not stop process", code: Int(errno))
            }
        }
    }
}
