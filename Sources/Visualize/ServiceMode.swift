import Foundation

enum ServiceMode: String, CaseIterable, Identifiable {
    case local = "Local"
    case compose = "Compose"
    case dockerfile = "Dockerfile"

    var id: String { rawValue }

    static func available(for service: ScanService) -> [Self] {
        allCases.filter {
            switch $0 {
            case .local: service.runModes.local.available && service.devCommand != nil
            case .compose: service.runModes.compose.available
            case .dockerfile: service.runModes.dockerfile.available
            }
        }
    }
}
