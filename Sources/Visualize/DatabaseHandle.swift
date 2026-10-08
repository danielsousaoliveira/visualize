import DatabaseDriver

final class DatabaseHandle: @unchecked Sendable {
    let pointer: OpaquePointer
    init(_ pointer: OpaquePointer) { self.pointer = pointer }
    deinit { vd_close(pointer) }
}
