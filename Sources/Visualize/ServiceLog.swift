import Foundation
import Observation

@MainActor
@Observable
final class ServiceLog {
    private(set) var lines: [LogLine] = []
    private(set) var revision = 0
    var error: String?
    let writer: LogFileWriter
    private var stdout = LogStreamDecoder()
    private var stderr = LogStreamDecoder()
    private var nextID = 0
    private var partial: [Bool: Int] = [:]

    init(fileURL: URL) {
        writer = LogFileWriter(url: fileURL)
        writer.append(Data())
    }

    var text: String { lines.map(\.text).joined(separator: "\n") }

    func append(_ data: Data, isError: Bool = false) {
        consume(isError ? stderr.decode(data) : stdout.decode(data), isError: isError)
    }

    func finish(isError: Bool) {
        consume(isError ? stderr.decode(Data(), final: true) : stdout.decode(Data(), final: true), isError: isError)
        partial[isError] = nil
        if isError { stderr = LogStreamDecoder() }
        else { stdout = LogStreamDecoder() }
    }

    private func consume(_ text: String, isError: Bool) {
        guard !text.isEmpty else { return }
        writer.append(Data(text.utf8))
        let parts = text.components(separatedBy: "\n")
        for (index, part) in parts.enumerated() {
            if index == parts.count - 1 && part.isEmpty { break }
            if let id = partial[isError], let position = lines.lastIndex(where: { $0.id == id }) {
                lines[position].text += part
            } else {
                lines.append(LogLine(id: nextID, text: part, isError: isError))
                partial[isError] = nextID
                nextID += 1
            }
            if index < parts.count - 1 { partial[isError] = nil }
        }
        if lines.count > 5000 { lines.removeFirst(lines.count - 5000) }
        revision += 1
    }

    func clear() { lines.removeAll(); partial.removeAll(); revision += 1 }
}
