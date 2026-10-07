import Foundation
import Darwin

struct OrderedOutputReader {
    private struct Chunk: Sendable {
        let data: Data?
        let isError: Bool
    }

    static func drain(stdout: FileHandle, stderr: FileHandle, receive: @escaping @MainActor @Sendable (Data?, Bool) -> Void) async {
        var handles = [(stdout, false), (stderr, true)]
        defer { try? stdout.close(); try? stderr.close() }
        while !handles.isEmpty {
            let chunks: [Chunk] = await withCheckedContinuation { continuation in
                let current = handles
                DispatchQueue.global(qos: .utility).async {
                    var descriptors = current.map { pollfd(fd: $0.0.fileDescriptor, events: Int16(POLLIN), revents: 0) }
                    var ready: Int32
                    repeat { ready = poll(&descriptors, nfds_t(descriptors.count), -1) } while ready < 0 && errno == EINTR
                    var chunks: [Chunk] = []
                    for index in current.indices where ready < 0 || descriptors[index].revents != 0 {
                        var bytes = [UInt8](repeating: 0, count: 65_536)
                        var count = -1
                        if ready >= 0 {
                            repeat { count = read(current[index].0.fileDescriptor, &bytes, bytes.count) } while count < 0 && errno == EINTR
                        }
                        chunks.append(Chunk(data: count > 0 ? Data(bytes.prefix(count)) : nil, isError: current[index].1))
                    }
                    continuation.resume(returning: chunks)
                }
            }
            for chunk in chunks {
                await receive(chunk.data, chunk.isError)
                if chunk.data == nil { handles.removeAll { $0.1 == chunk.isError } }
            }
        }
    }
}
