import Foundation

@MainActor
final class DockerLogFollower {
    private var processes: [Process] = []
    private var readers: [Task<Void, Never>] = []
    private var transition: Task<Void, Never>?
    private var generation = UUID()
    private var log: ServiceLog?

    func start(_ docker: DockerRun, directory: String, log: ServiceLog) {
        let cleanup = stop()
        let token = generation
        transition = Task {
            await cleanup.value
            guard generation == token else { return }
            self.log = log
            for container in docker.containerIDs {
                let process = Process()
                let output = Pipe()
                let errors = Pipe()
                process.executableURL = URL(filePath: docker.command.executable)
                process.arguments = ["--host", docker.command.endpoint, "logs", "-f", "--tail", "500", container]
                process.currentDirectoryURL = URL(filePath: directory)
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = output
                process.standardError = errors
                do {
                    try process.run()
                    processes.append(process)
                    try? output.fileHandleForWriting.close()
                    try? errors.fileHandleForWriting.close()
                    readers.append(Task.detached {
                        await OrderedOutputReader.drain(stdout: output.fileHandleForReading, stderr: errors.fileHandleForReading) { data, isError in
                            guard self.generation == token else { return }
                            if let data { log.append(data, isError: isError) }
                            else { log.finish(isError: isError) }
                        }
                    })
                } catch { log.error = "Could not follow Docker logs: \(error.localizedDescription)" }
            }
        }
    }

    @discardableResult
    func stop() -> Task<Void, Never> {
        generation = UUID()
        let previous = transition
        let cleanup = Task {
            await previous?.value
            for process in processes where process.isRunning { process.terminate() }
            let deadline = ContinuousClock.now.advanced(by: .seconds(1))
            while processes.contains(where: { $0.isRunning }) && ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            for process in processes {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                await Task.detached { process.waitUntilExit() }.value
            }
            for reader in readers { await reader.value }
            processes.removeAll()
            readers.removeAll()
            log?.finish(isError: false)
            log?.finish(isError: true)
            log = nil
        }
        transition = cleanup
        return cleanup
    }
}
