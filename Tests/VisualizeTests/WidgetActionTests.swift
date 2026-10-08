import Darwin
import Foundation
import Testing
@testable import visualize

@MainActor
struct WidgetActionTests {
    @Test func externalStopRequiresConfirmationAndRechecksListener() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let portFile = directory.appending(path: "port")
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/perl")
        process.arguments = ["-MIO::Socket::INET", "-e", "my $s = IO::Socket::INET->new(LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 1) or die $!; open my $f, '>', $ARGV[0] or die $!; print $f $s->sockport; close $f; sleep 60;", portFile.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            try? FileManager.default.removeItem(at: directory)
        }
        let state = AppState(store: ProjectLibraryStore(directory: directory.appending(path: "library")))
        defer { state.listenerStore.stop() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !FileManager.default.fileExists(atPath: portFile.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let port = try #require(Int(String(contentsOf: portFile, encoding: .utf8)))
        state.listenerStore.lowerPort = port
        state.listenerStore.upperPort = port
        while !state.listenerStore.listeners.contains(where: { $0.pid == process.processIdentifier }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let listener = try #require(state.listenerStore.listeners.first { $0.pid == process.processIdentifier })
        #expect(!listener.startedByVisualize)
        await state.widgetAction(listener)
        #expect(state.pendingWidgetStop?.id == listener.id)
        #expect(process.isRunning)
        state.pendingWidgetStop = nil
        #expect(process.isRunning)
        await state.widgetAction(listener, restart: true, externalStopConfirmed: true)
        #expect(process.isRunning)
        let stale = ProcessListener(port: listener.port, pid: listener.pid, name: listener.name, executablePath: nil, workingDirectory: nil,
            startedAt: ProcessIdentity(pid: listener.pid, seconds: (listener.identity?.seconds ?? 0) + 1, microseconds: 0),
            cpuPercent: nil, memoryBytes: nil, projectName: nil, projectFolder: nil, gitBranch: nil)
        await state.widgetAction(stale, externalStopConfirmed: true)
        #expect(process.isRunning)
        await state.widgetAction(listener, externalStopConfirmed: true)
        while process.isRunning, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!process.isRunning)
        #expect(state.pendingWidgetStop == nil)
    }
}
