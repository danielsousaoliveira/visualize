import Foundation
import Darwin

struct CommandOutput {
    let data: Data
    let status: Int32

    static func run(_ path: String, arguments: [String], timeout: TimeInterval = 5) throws -> Self {
        let process = Process()
        let exited = DispatchSemaphore(value: 0)
        let outputURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw NSError(domain: "Could not capture command output", code: 1)
        }
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let output = try FileHandle(forUpdating: outputURL)
        defer { try? output.close() }
        process.executableURL = URL(filePath: path)
        process.arguments = arguments
        // Inherit only HOME and a fixed PATH so ambient Docker endpoint and configuration variables cannot redirect lookups.
        process.environment = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        let maximumBytes = 1_048_576
        while exited.wait(timeout: .now() + 0.05) != .success {
            let size = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber)?.intValue ?? 0
            if ContinuousClock.now >= deadline || size > maximumBytes {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
                throw NSError(domain: size > maximumBytes ? "Command output exceeded limit" : "Command timed out: \(URL(filePath: path).lastPathComponent)", code: 1)
            }
        }
        guard process.terminationReason == .exit else {
            throw NSError(domain: "Command terminated unexpectedly", code: 1)
        }
        try output.seek(toOffset: 0)
        let data = try output.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw NSError(domain: "Command output exceeded limit", code: 1) }
        return Self(data: data, status: process.terminationStatus)
    }
}
