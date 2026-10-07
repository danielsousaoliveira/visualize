import Foundation

struct LogLine: Identifiable {
    let id: Int
    var text: String
    let isError: Bool
}
