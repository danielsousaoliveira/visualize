import Darwin
import Foundation
import Testing
@testable import visualize

struct TCPProbeTests {
    @Test func checksTCPAcceptanceRatherThanPortMetadata() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #expect(fd >= 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        #expect(bound == 0)
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let resolved = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
        }
        #expect(resolved == 0)
        let port = Int(UInt16(bigEndian: address.sin_port))
        #expect(!TCPProbe.accepts(port: port))
        #expect(listen(fd, 8) == 0)
        #expect(TCPProbe.accepts(port: port))
        #expect(!TCPProbe.accepts(port: 0))
        #expect(!TCPProbe.accepts(port: 65536))
    }
}
