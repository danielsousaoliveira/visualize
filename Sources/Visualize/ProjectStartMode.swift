import Foundation

enum ProjectStartMode: String, CaseIterable, Identifiable {
    case configured = "As configured"
    case local = "All local"
    case docker = "All in Docker"

    var id: String { rawValue }

    func resolve(_ service: ScanService, remembered: ServiceMode) -> ServiceMode? {
        let available = ServiceMode.available(for: service)
        switch self {
        case .configured: return available.contains(remembered) ? remembered : available.first
        case .local: return available.contains(.local) ? .local : available.first
        case .docker: return available.first { $0 != .local } ?? available.first
        }
    }
}
