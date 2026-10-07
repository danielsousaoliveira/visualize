import Foundation

@MainActor
final class DockerLogFollower {
    private var processes: [Process] = []
    private var generation = UUID()
    private var log: ServiceLog?

    func start(_ docker: DockerRun, directory: String, log: ServiceLog) {
        stop()
        self.log = log
        let token = generation
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
                for (pipe, isError) in [(output, false), (errors, true)] {
                    Task.detached {
                        while let data = try? await LocalProcess.readOutput(pipe.fileHandleForReading), !data.isEmpty {
                            await self.deliver(data, isError: isError, token: token, log: log)
                        }
                        try? pipe.fileHandleForReading.close()
                        await self.finish(isError: isError, token: token, log: log)
                    }
                }
            } catch { log.error = "Could not follow Docker logs: \(error.localizedDescription)" }
        }
    }

    private func deliver(_ data: Data, isError: Bool, token: UUID, log: ServiceLog) {
        guard generation == token else { return }
        log.append(data, isError: isError)
    }

    private func finish(isError: Bool, token: UUID, log: ServiceLog) {
        guard generation == token else { return }
        log.finish(isError: isError)
    }

    func stop() {
        generation = UUID()
        log?.finish(isError: false)
        log?.finish(isError: true)
        log = nil
        for process in processes where process.isRunning {
            process.terminate()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        processes.removeAll()
    }
}
