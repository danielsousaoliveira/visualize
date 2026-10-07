import Darwin
import Foundation

struct OwnedProcessGroup: Sendable {
    let pid: Int32
    let seconds: UInt64
    let microseconds: UInt64

    static func capture(_ pid: Int32) -> Self? {
        guard pid > 1, pid != getpgrp() else { return nil }
        var info = proc_bsdinfo()
        if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size, getpgid(pid) == pid {
            return Self(pid: pid, seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
        }
        var query: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var process = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        guard sysctl(&query, UInt32(query.count), &process, &size, nil, 0) == 0,
              size == MemoryLayout<kinfo_proc>.size, process.kp_proc.p_pid == pid,
              Int32(process.kp_proc.p_stat) == SZOMB, process.kp_eproc.e_pgid == pid,
              process.kp_eproc.e_ppid == getpid() else { return nil }
        let started = process.kp_proc.p_un.__p_starttime
        return Self(pid: pid, seconds: UInt64(started.tv_sec), microseconds: UInt64(started.tv_usec))
    }

    func contains(_ owner: PortOwner) -> Bool {
        // Process queries are not atomic; signal(_:) revalidates the captured group identity before sending a signal.
        guard owner.containerID == nil, owner.pid > 1, owner.uid == getuid(), owner.uid != 0,
              let current = Self.capture(pid), current.seconds == seconds,
              current.microseconds == microseconds, getpgid(owner.pid) == pid else { return false }
        var info = proc_bsdinfo()
        guard proc_pidinfo(owner.pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size else { return false }
        return info.pbi_uid == owner.uid && info.pbi_start_tvsec == owner.seconds &&
            info.pbi_start_tvusec == owner.microseconds && getpgid(owner.pid) == pid
    }

    var exists: Bool {
        errno = 0
        let bytes = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(pid), nil, 0)
        if bytes == 0 && errno == 0 { return false }
        guard bytes > 0 else { return !confirmedGone }
        var members = [Int32](repeating: 0, count: Int(bytes) / MemoryLayout<Int32>.size + 32)
        errno = 0
        let count = members.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(pid), $0.baseAddress, Int32($0.count)) }
        if count == 0 && errno == 0 { return false }
        guard count > 0 else { return !confirmedGone }
        return members.prefix(Int(count) / MemoryLayout<Int32>.size).contains { member in
            var info = proc_bsdinfo()
            guard member > 0 else { return false }
            guard proc_pidinfo(member, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size else {
                if errno == ESRCH { return false }
                return kill(member, 0) == 0 || errno != ESRCH
            }
            return info.pbi_status != SZOMB
        }
    }

    var confirmedGone: Bool { kill(-pid, 0) == -1 && errno == ESRCH }

    func signal(_ signal: Int32) -> Bool {
        guard exists, let current = Self.capture(pid), current.seconds == seconds,
              current.microseconds == microseconds else { return false }
        return kill(-pid, signal) == 0
    }

    func stop() async -> Bool {
        guard signal(SIGTERM) else { return false }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while exists && clock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        if exists && !signal(SIGKILL) { return false }
        while exists { try? await Task.sleep(for: .milliseconds(50)) }
        return true
    }
}
