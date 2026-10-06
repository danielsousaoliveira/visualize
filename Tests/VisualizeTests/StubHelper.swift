import Foundation

struct StubHelper {
    let directory: URL
    let executable: URL

    init(script: (URL) -> String) throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "visualize-stub-\(UUID().uuidString)")
        executable = directory.appending(path: "visualize-scan")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try ("#!/bin/sh\n" + script(directory)).write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    func file(_ name: String) -> URL {
        directory.appending(path: name)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
