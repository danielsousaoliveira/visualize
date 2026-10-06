import Foundation

struct ScanHelper: Sendable {
    static let executableName = "visualize-scan"
    static let defaultTimeout: TimeInterval = 30

    private static let environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
    private static let stderrLineLimit = 5
    private static let terminationGrace: TimeInterval = 2

    let executableURL: URL
    let timeout: TimeInterval

    init(executableURL: URL, timeout: TimeInterval = defaultTimeout) {
        self.executableURL = executableURL
        self.timeout = timeout
    }

    static func bundled(in bundle: Bundle = .main) -> ScanHelper {
        ScanHelper(executableURL: bundle.bundleURL.appending(path: "Contents/Helpers/\(executableName)"))
    }

    func scan(folder: URL) async throws -> ScanResult {
        let output = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try run(folder: folder) })
            }
        }
        return try Self.decode(output)
    }

    private func run(folder: URL) throws -> Data {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path(percentEncoded: false)) else {
            throw ScanError.helperMissing
        }

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let exited = DispatchSemaphore(value: 0)
        process.executableURL = executableURL
        process.arguments = [folder.path(percentEncoded: false)]
        process.environment = Self.environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            throw ScanError.launchFailed(error.localizedDescription)
        }
        let output = PipeDrain(stdout.fileHandleForReading)
        let errors = PipeDrain(stderr.fileHandleForReading)

        guard exited.wait(timeout: .now() + timeout) == .success else {
            stop(process, exited: exited)
            throw ScanError.timedOut(seconds: Int(timeout))
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw ScanError.helperFailed(
                status: process.terminationStatus,
                stderr: Self.leadingLines(of: errors.wait())
            )
        }
        return output.wait()
    }

    private func stop(_ process: Process, exited: DispatchSemaphore) {
        process.terminate()
        if exited.wait(timeout: .now() + Self.terminationGrace) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            exited.wait()
        }
    }

    private static func leadingLines(of data: Data) -> String {
        String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .prefix(stderrLineLimit)
            .joined(separator: "\n")
    }

    private static func decode(_ data: Data) throws -> ScanResult {
        do {
            return try ScanDecoder.decode(data)
        } catch ScanDecodingError.unsupportedVersion(let version) {
            throw ScanError.unsupportedVersion(version)
        } catch ScanDecodingError.malformed(let detail) {
            throw ScanError.invalidOutput(detail)
        }
    }
}
