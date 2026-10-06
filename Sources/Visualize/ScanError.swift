import Foundation

enum ScanError: Error, Equatable, LocalizedError {
    case helperMissing
    case launchFailed(String)
    case helperFailed(status: Int32, stderr: String)
    case timedOut(seconds: Int)
    case invalidOutput(String)
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .helperMissing:
            "The scan helper is missing from the app bundle. Rebuild visualize with scripts/build-app.sh."
        case .launchFailed(let reason):
            "The scan helper could not be started: \(reason)"
        case .helperFailed(let status, let stderr) where stderr.isEmpty:
            "The scan helper exited with status \(status)."
        case .helperFailed(let status, let stderr):
            "The scan helper exited with status \(status):\n\(stderr)"
        case .timedOut(let seconds):
            "The scan took longer than \(seconds) seconds and was stopped."
        case .invalidOutput(let detail):
            "The scan helper returned invalid output: \(detail)"
        case .unsupportedVersion(let version):
            ScanDecodingError.unsupportedVersion(version).errorDescription
        }
    }
}
