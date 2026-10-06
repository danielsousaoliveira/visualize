import Foundation

enum ScanStatus: Equatable {
    case idle
    case scanning(URL)
    case finished(String)
    case failed(String)
}
