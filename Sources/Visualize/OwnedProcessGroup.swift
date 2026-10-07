import Darwin
import Foundation

struct OwnedProcessGroup: Sendable {
    let pid: Int32
    let seconds: UInt64
    let microseconds: UInt64

    static func capture(_ pid: Int32) -> Self? {
        guard pid > 1, pid != getpgrp(), getpgid(pid) == pid else { return nil }
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size else { return nil }
        return Self(pid: pid, seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
    }

    var exists: Bool {
        let bytes = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(pid), nil, 0)
        guard bytes > 0 else { return !confirmedGone }
        var members = [Int32](repeating: 0, count: Int(bytes) / MemoryLayout<Int32>.size + 32)
        let count = members.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(pid), $0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return !confirmedGone }
        return members.prefix(Int(count) / MemoryLayout<Int32>.size).contains { member in
            var info = proc_bsdinfo()
            guard member > 0 else { return false }
            guard proc_pidinfo(member, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size else {
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
