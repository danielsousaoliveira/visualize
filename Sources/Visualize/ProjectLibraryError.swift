import Foundation

enum ProjectLibraryError: Error, Equatable, LocalizedError {
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            "The project library has version \(version), which this version of visualize cannot read."
        }
    }
}
