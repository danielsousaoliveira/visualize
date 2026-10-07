import Darwin

struct ServiceOutputDrainer {
    static func run() {
        signal(SIGPIPE, SIG_IGN)
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var forwarding = true
        while true {
            let count = read(STDIN_FILENO, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { return }
            guard forwarding else { continue }
            buffer.withUnsafeBytes { bytes in
                var offset = 0
                while offset < count {
                    let written = write(STDOUT_FILENO, bytes.baseAddress!.advanced(by: offset), count - offset)
                    if written < 0 && errno == EINTR { continue }
                    if written <= 0 { forwarding = false; break }
                    offset += written
                }
            }
        }
    }
}
