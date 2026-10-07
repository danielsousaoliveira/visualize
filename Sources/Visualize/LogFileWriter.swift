import Foundation

final class LogFileWriter: @unchecked Sendable {
    let url: URL
    private let queue = DispatchQueue(label: "visualize.log-file")
    private let limit: Int
    private var failure: String?

    init(url: URL, limit: Int = 10_000_000) {
        self.url = url
        self.limit = limit
    }

    func append(_ data: Data) {
        queue.async { [self] in
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                if !FileManager.default.fileExists(atPath: url.path) {
                    guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
                }
                var offset = 0
                while offset < data.count {
                    if !FileManager.default.fileExists(atPath: url.path) {
                        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                            throw CocoaError(.fileWriteUnknown)
                        }
                    }
                    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                    guard let size = (attributes[.size] as? NSNumber)?.intValue else { throw CocoaError(.fileReadUnknown) }
                    if size >= limit { try rotate(); continue }
                    let handle = try FileHandle(forWritingTo: url)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    let end = min(data.count, offset + limit - size)
                    try handle.write(contentsOf: data[offset..<end])
                    offset = end
                }
            } catch { failure = error.localizedDescription }
        }
    }

    private func rotate() throws {
        let manager = FileManager.default
        let oldest = URL(filePath: url.path + ".3")
        if manager.fileExists(atPath: oldest.path) { try manager.removeItem(at: oldest) }
        for index in stride(from: 2, through: 0, by: -1) {
            let source = index == 0 ? url : URL(filePath: url.path + ".\(index)")
            if manager.fileExists(atPath: source.path) {
                try manager.moveItem(at: source, to: URL(filePath: url.path + ".\(index + 1)"))
            }
        }
    }

    func flush() async -> String? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in continuation.resume(returning: failure) }
        }
    }
}
