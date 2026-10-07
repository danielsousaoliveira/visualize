import Foundation

struct DockerCommand: Sendable {
    let executable: String
    let endpoint: String

    private static func error(_ message: String) -> NSError {
        NSError(domain: "VisualizeDocker", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    static func connect(overridePath: String?) throws -> Self {
        let paths = overridePath.map { [NSString(string: $0).expandingTildeInPath] } ?? DockerChecker().searchPaths
        guard let executable = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
              let context = try? CommandOutput.run(executable, arguments: ["context", "show"]), context.status == 0 else {
            throw Self.error("Docker CLI unavailable")
        }
        let name = String(decoding: context.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let result = try CommandOutput.run(executable, arguments: ["context", "inspect", name, "--format", "{{json .Endpoints.docker.Host}}"])
        guard result.status == 0, let endpoint = try? JSONDecoder().decode(String.self, from: result.data), endpoint.hasPrefix("unix:///") else {
            throw Self.error("Docker requires a local Unix socket")
        }
        return Self(executable: executable, endpoint: endpoint)
    }

    func run(_ arguments: [String], directory: String, output: @escaping @MainActor @Sendable (Data) -> Void = { _ in }) async throws -> Data {
        try await Task.detached {
            let process = Process()
            let outputURL = FileManager.default.temporaryDirectory.appending(path: "visualize-docker-output-\(UUID().uuidString)")
            guard FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw Self.error("Could not capture Docker output")
            }
            defer { try? FileManager.default.removeItem(at: outputURL) }
            let writer = try FileHandle(forWritingTo: outputURL)
            let reader = try FileHandle(forReadingFrom: outputURL)
            defer { try? writer.close(); try? reader.close() }
            process.executableURL = URL(filePath: executable)
            process.arguments = ["--host", endpoint] + arguments
            process.currentDirectoryURL = URL(filePath: directory)
            process.environment = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path, "PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = writer
            process.standardError = writer
            try process.run()
            defer { if process.isRunning { process.terminate() } }
            let deadline = ContinuousClock.now.advanced(by: .seconds(arguments.first == "build" || arguments.contains("up") ? 600 : 60))
            var captured = Data()
            var finished = false
            while true {
                finished = !process.isRunning
                for _ in 0..<16 {
                    guard let chunk = try reader.read(upToCount: 65_536), !chunk.isEmpty else { break }
                    captured.append(chunk)
                    if captured.count > 1_048_576 { captured.removeFirst(captured.count - 1_048_576) }
                    await output(chunk)
                }
                let totalSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber)?.intValue ?? 0
                guard totalSize <= 67_108_864 else { throw Self.error("Docker output exceeded 64 MB") }
                if finished, reader.offsetInFile >= UInt64(totalSize) { break }
                if ContinuousClock.now >= deadline {
                    process.terminate()
                    let grace = ContinuousClock.now.advanced(by: .seconds(2))
                    while process.isRunning, ContinuousClock.now < grace { try await Task.sleep(for: .milliseconds(50)) }
                    if process.isRunning {
                        kill(process.processIdentifier, SIGKILL)
                        while process.isRunning { try await Task.sleep(for: .milliseconds(50)) }
                    }
                    throw Self.error("Docker command timed out")
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard process.terminationReason == .exit, process.terminationStatus == 0 else {
                throw Self.error("Docker command failed (\(process.terminationStatus))")
            }
            return captured
        }.value
    }
}
