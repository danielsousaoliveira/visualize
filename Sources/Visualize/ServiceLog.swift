import Foundation
import Observation

@MainActor
@Observable
final class ServiceLog {
    private(set) var lines: [LogLine] = []
    private(set) var revision = 0
    var error: String?
    @ObservationIgnored let dockerFollower = DockerLogFollower()
    let writer: LogFileWriter
    private var stdout = LogStreamDecoder()
    private var stderr = LogStreamDecoder()
    private var nextID = 0
    private var partial: [Bool: Int] = [:]
    private var diskStream: Bool?
    private var diskLineOpen = false
    private var viewStream: Bool?

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
        if diskLineOpen && diskStream == isError {
            writer.append(Data("\n".utf8))
            diskLineOpen = false
        }
        if isError { stderr = LogStreamDecoder() }
        else { stdout = LogStreamDecoder() }
    }

    private func consume(_ text: String, isError: Bool) {
        guard !text.isEmpty else { return }
        if viewStream != isError { partial.removeAll() }
        viewStream = isError
        if diskLineOpen && diskStream != isError {
            writer.append(Data("\n".utf8))
            diskLineOpen = false
        }
        diskStream = isError
        var savedChunk = ""
        let parts = text.components(separatedBy: "\n")
        for (index, part) in parts.enumerated() {
            if index == parts.count - 1 && part.isEmpty { break }
            var saved = diskLineOpen ? "" : (isError ? "[stderr] " : "[stdout] ")
            saved += part
            diskLineOpen = index == parts.count - 1
            if !diskLineOpen { saved += "\n" }
            savedChunk += saved
            if let id = partial[isError], let position = lines.lastIndex(where: { $0.id == id }) {
                lines[position].text += part
            } else {
                lines.append(LogLine(id: nextID, text: part, isError: isError))
                partial[isError] = nextID
                nextID += 1
            }
            if index < parts.count - 1 { partial[isError] = nil }
        }
        writer.append(Data(savedChunk.utf8))
        if lines.count > 5000 { lines.removeFirst(lines.count - 5000) }
        revision += 1
    }

    func clear() { lines.removeAll(); partial.removeAll(); revision += 1 }
}
