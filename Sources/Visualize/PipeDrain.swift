import Foundation

final class PipeDrain: @unchecked Sendable {
    private let finished = DispatchSemaphore(value: 0)
    private var data = Data()

    init(_ handle: FileHandle) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            data = handle.readDataToEndOfFile()
            finished.signal()
        }
    }

    func wait() -> Data {
        finished.wait()
        finished.signal()
        return data
    }
}
