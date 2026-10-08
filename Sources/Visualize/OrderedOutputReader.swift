import Foundation
import Darwin

struct OrderedOutputReader {
    struct Chunk: Sendable {
        let data: Data?
        let isError: Bool
        let failure: String?
    }

    static func readResult(_ count: Int, error: Int32 = 0, isError: Bool) -> Chunk {
        if count > 0 { return Chunk(data: Data(repeating: 0, count: count), isError: isError, failure: nil) }
        if count == 0 { return Chunk(data: nil, isError: isError, failure: nil) }
        return Chunk(data: nil, isError: isError, failure: String(cString: strerror(error)))
    }

    static func drain(stdout: FileHandle, stderr: FileHandle, receive: @escaping @MainActor @Sendable (Data?, Bool) -> Void, failed: @escaping @MainActor @Sendable (String, Bool) -> Void = { _, _ in }) async {
        var handles = [(stdout, false), (stderr, true)]
        defer { try? stdout.close(); try? stderr.close() }
        while !handles.isEmpty {
            let chunks: [Chunk] = await withCheckedContinuation { continuation in
                let current = handles
                DispatchQueue.global(qos: .utility).async {
                    var descriptors = current.map { pollfd(fd: $0.0.fileDescriptor, events: Int16(POLLIN), revents: 0) }
                    var invalid = Set<Int>()
                    for index in current.indices where fcntl(current[index].0.fileDescriptor, F_GETFD) == -1 { invalid.insert(index) }
                    var ready: Int32
                    if !invalid.isEmpty { ready = 1 }
                    else {
                        repeat { ready = poll(&descriptors, nfds_t(descriptors.count), -1) } while ready < 0 && errno == EINTR
                    }
                    var chunks: [Chunk] = []
                    for index in invalid { chunks.append(Chunk(data: nil, isError: current[index].1, failure: "Invalid output descriptor")) }
                    if ready < 0 {
                        let message = String(cString: strerror(errno))
                        for (index, stream) in current.enumerated() where !invalid.contains(index) { chunks.append(Chunk(data: nil, isError: stream.1, failure: message)) }
                    }
                    for index in current.indices where ready >= 0 && !invalid.contains(index) && descriptors[index].revents != 0 {
                        let events = descriptors[index].revents
                        if events & Int16(POLLNVAL | POLLERR) != 0 {
                            chunks.append(Chunk(data: nil, isError: current[index].1, failure: events & Int16(POLLNVAL) != 0 ? "Invalid output descriptor" : "Output stream poll failed"))
                            continue
                        }
                        var bytes = [UInt8](repeating: 0, count: 65_536)
                        var count: Int
                        repeat { count = read(current[index].0.fileDescriptor, &bytes, bytes.count) } while count < 0 && errno == EINTR
                        if count < 0 { chunks.append(readResult(count, error: errno, isError: current[index].1)) }
                        else if count > 0 {
                            chunks.append(Chunk(data: Data(bytes.prefix(count)), isError: current[index].1, failure: nil))
                        } else { chunks.append(readResult(0, isError: current[index].1)) }
                    }
                    continuation.resume(returning: chunks)
                }
            }
            for chunk in chunks {
                if let failure = chunk.failure { await failed(failure, chunk.isError) }
                else { await receive(chunk.data, chunk.isError) }
                if chunk.data == nil { handles.removeAll { $0.1 == chunk.isError } }
            }
        }
    }
}
