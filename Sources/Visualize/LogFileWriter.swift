import Foundation
import Darwin

final class LogFileWriter: @unchecked Sendable {
    let url: URL
    private let queue = DispatchQueue(label: "visualize.log-file")
    private var limit: Int
    private var failure: String?

    init(url: URL, limit: Int = 10_000_000) {
        self.url = url
        self.limit = limit
    }

    func setRetention(megabytes: Int) {
        queue.async { [self] in
            limit = megabytes * 1_000_000 / 4
            do {
                for index in 0...3 {
                    let path = index == 0 ? url.path : "\(url.path).\(index)"
                    try verifyRegularFile(path)
                    let descriptor = open(path, O_WRONLY | O_NOFOLLOW)
                    if descriptor < 0 {
                        if errno == ENOENT { continue }
                        throw systemError()
                    }
                    defer { close(descriptor) }
                    var metadata = stat()
                    guard fstat(descriptor, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFREG else { throw fileError("Log path is not a regular file") }
                    if metadata.st_size > limit, ftruncate(descriptor, off_t(limit)) != 0 { throw systemError() }
                }
            } catch { failure = error.localizedDescription }
        }
    }

    func append(_ data: Data) {
        queue.async { [self] in
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                guard !data.isEmpty else { return }
                var offset = 0
                while offset < data.count {
                    let descriptor = try openLog(create: true)
                    defer { close(descriptor) }
                    var metadata = stat()
                    guard fstat(descriptor, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFREG else { throw fileError("Log path is not a regular file") }
                    let size = Int(metadata.st_size)
                    if size >= limit {
                        try rotate()
                        continue
                    }
                    guard lseek(descriptor, 0, SEEK_END) >= 0 else { throw systemError() }
                    let count = min(data.count - offset, limit - size)
                    let written = data.withUnsafeBytes { bytes -> Int in
                        guard let base = bytes.baseAddress else { return 0 }
                        return write(descriptor, base.advanced(by: offset), count)
                    }
                    guard written > 0 else { throw systemError() }
                    offset += written
                }
            } catch { failure = error.localizedDescription }
        }
    }

    private func openLog(create: Bool) throws -> Int32 {
        let descriptor = open(url.path, O_WRONLY | O_APPEND | O_NOFOLLOW | (create ? O_CREAT : 0), mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else { throw systemError() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFREG else {
            close(descriptor)
            throw fileError("Log path is not a regular file")
        }
        return descriptor
    }

    private func verifyRegularFile(_ path: String) throws {
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else {
            if errno == ENOENT { return }
            throw systemError()
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG else { throw fileError("Log path is not a regular file") }
    }

    private func rotate() throws {
        for index in 0...3 { try verifyRegularFile(index == 0 ? url.path : "\(url.path).\(index)") }
        let oldest = "\(url.path).3"
        if unlink(oldest) != 0 && errno != ENOENT { throw systemError() }
        for index in stride(from: 2, through: 0, by: -1) {
            let source = index == 0 ? url.path : "\(url.path).\(index)"
            let destination = "\(url.path).\(index + 1)"
            if rename(source, destination) != 0 && errno != ENOENT { throw systemError() }
        }
    }

    private func systemError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))])
    }

    private func fileError(_ message: String) -> NSError {
        NSError(domain: "VisualizeLogFile", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    func flush() async -> String? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in continuation.resume(returning: failure) }
        }
    }
}
