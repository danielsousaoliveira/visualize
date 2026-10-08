import Foundation
import Darwin

final class ProcessListenerMonitor: @unchecked Sendable {
    private var previousCPU: [ProcessIdentity: (UInt64, ContinuousClock.Instant)] = [:]

    func scan(ports: ClosedRange<Int> = 1024...65535, projects: [Project]) -> [ProcessListener] {
        let records = Self.discover(ports: ports)
        let trees = Dictionary(uniqueKeysWithValues: Set(records.map(\.pid)).map { ($0, Self.descendants(of: $0)) })
        var samples: [Int32: Sample] = [:]
        for pid in Set(trees.values.flatMap { $0 }) { samples[pid] = sample(pid) }
        return records.compactMap { record in
            guard let sample = samples[record.pid], sample.identity != nil,
                  !sample.executablePath.split(separator: "/").contains(where: { $0.hasSuffix(".app") }) else { return nil }
            let directory = sample.workingDirectory
            let project = directory.flatMap { path in
                projects.filter { path == $0.folderPath || path.hasPrefix($0.folderPath + "/") }
                    .max { $0.folderPath.count < $1.folderPath.count }
            }
            let scanned = project?.lastResult?.project
            let treeSamples = (trees[record.pid] ?? [record.pid]).compactMap { samples[$0] }
            let cpu = treeSamples.compactMap(\.cpuPercent).reduce(0, +)
            let memory = treeSamples.compactMap(\.memoryBytes).reduce(UInt64(0), &+)
            return ProcessListener(port: record.port, pid: record.pid, name: record.name,
                                   executablePath: sample.executablePath, workingDirectory: directory,
                                   startedAt: sample.identity, cpuPercent: treeSamples.contains(where: { $0.cpuPercent != nil }) ? cpu : nil,
                                   memoryBytes: memory == 0 ? nil : memory, projectName: scanned?.name ?? project?.name,
                                   projectFolder: scanned?.rootPath ?? project?.folderPath,
                                   gitBranch: scanned?.gitBranch)
        }
    }

    private struct Record { let port: Int; let pid: Int32; let name: String }
    private struct Sample {
        let identity: ProcessIdentity?
        let executablePath: String
        let workingDirectory: String?
        let cpuPercent: Double?
        let memoryBytes: UInt64?
    }

    private static func discover(ports: ClosedRange<Int>) -> [Record] {
        guard let output = try? CommandOutput.run("/usr/sbin/lsof", arguments: ["-nP", "-iTCP", "-sTCP:LISTEN"]),
              output.status == 0 || output.status == 1 else { return [] }
        var records: [Record] = []
        let lines = String(decoding: output.data, as: UTF8.self).split(separator: "\n")
        for line in lines.dropFirst() {
            let columns = line.split(whereSeparator: \.isWhitespace)
            guard columns.count >= 9, let pid = Int32(columns[1]), let uid = UInt32(columns[2]), uid == getuid(),
                  let port = Self.listeningPort(String(columns[8])), ports.contains(port) else { continue }
            let process = String(columns[0])
            if !records.contains(where: { $0.pid == pid && $0.port == port }) {
                records.append(Record(port: port, pid: pid, name: process))
            }
        }
        return records
    }

    private static func listeningPort(_ endpoint: String) -> Int? {
        let local = endpoint.components(separatedBy: "->").first ?? endpoint
        guard let colon = local.lastIndex(of: ":") else { return nil }
        return Int(local[local.index(after: colon)...])
    }

    private static func descendants(of root: Int32) -> [Int32] {
        var buffer = [Int32](repeating: 0, count: 131_072)
        let count = buffer.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return [root] }
        let pids = buffer.prefix(Int(count))
        var parents: [Int32: Int32] = [:]
        for offset in stride(from: 0, to: pids.count, by: 256) {
            for pid in pids.dropFirst(offset).prefix(256) where pid > 1 {
                var query = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
                var info = kinfo_proc()
                var size = MemoryLayout<kinfo_proc>.size
                guard sysctl(&query, UInt32(query.count), &info, &size, nil, 0) == 0,
                      size == MemoryLayout<kinfo_proc>.size, info.kp_proc.p_pid == pid else { continue }
                parents[pid] = info.kp_eproc.e_ppid
            }
        }
        var result: Set<Int32> = [root]
        var changed = true
        while changed {
            changed = false
            for (pid, parent) in parents where result.contains(parent) && result.insert(pid).inserted { changed = true }
        }
        return Array(result)
    }

    private func sample(_ pid: Int32) -> Sample {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
              info.pbi_uid == getuid() else {
            return Sample(identity: nil, executablePath: "", workingDirectory: nil, cpuPercent: nil, memoryBytes: nil)
        }
        let identity = ProcessIdentity(pid: pid, seconds: UInt64(info.pbi_start_tvsec), microseconds: UInt64(info.pbi_start_tvusec))
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN * 4))
        let pathLength = pathBuffer.withUnsafeMutableBufferPointer { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        let path = pathLength > 0 ? String(decoding: pathBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) : ""
        var vnode = proc_vnodepathinfo()
        let cwd: String? = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnode, Int32(MemoryLayout<proc_vnodepathinfo>.size)) == MemoryLayout<proc_vnodepathinfo>.size
            ? withUnsafePointer(to: &vnode.pvi_cdir.vip_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            } : nil
        let usage = Self.resourceUsage(pid)
        let now = ContinuousClock.now
        let cpu = usage.map { value in
            previousCPU[identity].map { previous in
                Double(value.ri_user_time &+ value.ri_system_time &- previous.0) / max(0.001, Double(previous.1.duration(to: now).components.seconds)) / 10_000
            }
        }
        if let usage { previousCPU[identity] = (usage.ri_user_time &+ usage.ri_system_time, now) }
        return Sample(identity: identity, executablePath: path, workingDirectory: cwd, cpuPercent: cpu ?? nil, memoryBytes: usage?.ri_resident_size)
    }

    private static func resourceUsage(_ pid: Int32) -> rusage_info_v0? {
        var pointer: rusage_info_t?
        guard proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, &pointer) == 0, let pointer else { return nil }
        return pointer.assumingMemoryBound(to: rusage_info_v0.self).pointee
    }
}
