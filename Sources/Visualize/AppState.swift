import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    var projects: [Project] = []
    var runningServices: [RunningService] = []
    private(set) var scanStatus: ScanStatus = .idle

    private let scanHelper: ScanHelper

    init(scanHelper: ScanHelper = .bundled()) {
        self.scanHelper = scanHelper
    }

    var isScanning: Bool {
        if case .scanning = scanStatus { true } else { false }
    }

    func scan(folder: URL) {
        guard !isScanning else { return }
        scanStatus = .scanning(folder)
        let helper = scanHelper
        Task {
            do {
                scanStatus = .finished(try await helper.scan(folder: folder).summary)
            } catch {
                scanStatus = .failed(error.localizedDescription)
            }
        }
    }
}
