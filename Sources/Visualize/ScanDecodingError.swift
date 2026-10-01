import Foundation

enum ScanDecodingError: Error, Equatable, LocalizedError {
    case unsupportedVersion(Int)
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            "Unsupported scan version \(version). Update visualize to read this scan."
        case .malformed(let detail):
            "The scan output could not be read: \(detail)"
        }
    }
}
