import Foundation

struct LogStreamDecoder {
    private var bytes = Data()
    private var escape = 0

    mutating func decode(_ data: Data, final: Bool = false) -> String {
        var clean = Data()
        for byte in data {
            switch escape {
            case 1:
                if byte == 91 { escape = 2 }
                else if byte == 93 { escape = 3 }
                else { escape = 0 }
            case 2:
                if byte >= 64 && byte <= 126 { escape = 0 }
            case 3:
                if byte == 7 { escape = 0 }
                else if byte == 27 { escape = 4 }
            case 4:
                escape = byte == 92 ? 0 : 3
            default:
                if byte == 27 { escape = 1 }
                else if byte >= 32 || byte == 9 || byte == 10 { clean.append(byte) }
            }
        }
        bytes.append(clean)
        var end = bytes.count
        if !final, end > 0 {
            var start = end - 1
            while start > 0 && bytes[start] & 0xc0 == 0x80 { start -= 1 }
            let lead = bytes[start]
            let length = lead & 0xf8 == 0xf0 ? 4 : lead & 0xf0 == 0xe0 ? 3 : lead & 0xe0 == 0xc0 ? 2 : 1
            if end - start < length { end = start }
        }
        let text = String(decoding: bytes.prefix(end), as: UTF8.self)
        bytes = Data(bytes.dropFirst(end))
        return text
    }
}
