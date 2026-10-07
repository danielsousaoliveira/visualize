import Foundation
import Darwin

struct LocalProcess {
    static func readOutput(_ handle: FileHandle) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var buffer = [UInt8](repeating: 0, count: 65_536)
                var count: Int
                repeat { count = read(handle.fileDescriptor, &buffer, buffer.count) } while count < 0 && errno == EINTR
                if count < 0 { continuation.resume(throwing: NSError(domain: NSPOSIXErrorDomain, code: Int(errno))) }
                else { continuation.resume(returning: count == 0 ? nil : Data(buffer.prefix(count))) }
            }
        }
    }

    static func waitForExit(_ pid: Int32) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var info = siginfo_t()
                while waitid(P_PID, UInt32(pid), &info, WEXITED | WNOWAIT) == -1 && errno == EINTR {}
                continuation.resume()
            }
        }
    }

    static func environment() async throws -> [String: String] {
        try await Task.detached {
            let process = Process()
            let outputURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            guard FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw NSError(domain: "Could not capture login environment", code: 1)
            }
            let output = try FileHandle(forUpdating: outputURL)
            defer { try? output.close(); try? FileManager.default.removeItem(at: outputURL) }
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? String(cString: getpwuid(getuid()).pointee.pw_shell)
            process.executableURL = URL(filePath: shell)
            process.arguments = ["-ilc", "/usr/bin/env -0"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let deadline = Date().addingTimeInterval(10)
            while process.isRunning && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
            if process.isRunning { process.terminate(); kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw NSError(domain: "Login shell environment could not be captured", code: 1) }
            try output.seek(toOffset: 0)
            let data = try output.readToEnd() ?? Data()
            var result: [String: String] = [:]
            for entry in data.split(separator: 0) {
                let value = String(decoding: entry, as: UTF8.self)
                guard let separator = value.firstIndex(of: "=") else { continue }
                let key = String(value[..<separator])
                guard !key.isEmpty, !key.contains("\n") else { continue }
                result[key] = String(value[value.index(after: separator)...])
            }
            guard result["PATH"] != nil else { throw NSError(domain: "Login shell did not return PATH", code: 1) }
            return result
        }.value
    }

    static func start(_ recipe: RunRecipe, environment: [String: String], outputDrainerURL: URL? = nil, stderr: Pipe? = nil) throws -> (Int32, FileHandle) {
        guard let executable = recipe.argv.first, !executable.isEmpty,
              !recipe.argv.contains(where: { $0.contains("\0") }) else { throw NSError(domain: "Invalid command", code: 1) }
        let candidates = executable.contains("/") ? [NSString(string: executable).isAbsolutePath ? executable : URL(filePath: recipe.workingDirectory).appending(path: executable).path] :
            (environment["PATH"] ?? "").components(separatedBy: ":").map { directory in
                URL(filePath: directory.isEmpty ? recipe.workingDirectory : directory, relativeTo: URL(filePath: recipe.workingDirectory + "/")).appending(path: executable).path
            }
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw NSError(domain: "Tool not found in login PATH: \(executable)", code: 1)
        }
        let serviceOutput = Pipe()
        let capturedOutput = Pipe()
        let drainer = Process()
        drainer.executableURL = outputDrainerURL ?? Bundle.main.executableURL
        drainer.arguments = ["--drain-service-output"]
        drainer.standardInput = serviceOutput.fileHandleForReading
        drainer.standardOutput = capturedOutput.fileHandleForWriting
        drainer.standardError = FileHandle.nullDevice
        try drainer.run()
        try? serviceOutput.fileHandleForReading.close()
        try? capturedOutput.fileHandleForWriting.close()
        defer { try? serviceOutput.fileHandleForWriting.close(); try? stderr?.fileHandleForWriting.close() }
        let reader = capturedOutput.fileHandleForReading
        var launched = false
        defer { if !launched { try? reader.close() } }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signal in [SIGTERM, SIGINT, SIGHUP, SIGPIPE] { sigaddset(&defaults, signal) }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)
        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, serviceOutput.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stderr?.fileHandleForWriting.fileDescriptor ?? serviceOutput.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
        let directoryError = posix_spawn_file_actions_addchdir_np(&actions, recipe.workingDirectory)
        guard directoryError == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(directoryError)) }
        let argv = recipe.argv.map { strdup($0) } + [nil]
        let env = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; env.forEach { free($0) } }
        var pid: pid_t = 0
        let result = argv.withUnsafeBufferPointer { arguments in
            env.withUnsafeBufferPointer { values in
                posix_spawn(&pid, path, &actions, &attributes, arguments.baseAddress!, values.baseAddress!)
            }
        }
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(result)) }
        launched = true
        return (pid, reader)
    }

    static func listening(port: Int, processGroup: Int32) -> Bool {
        (try? PortOwnerLookup.owners(port: port, includeDocker: false).contains { getpgid($0.pid) == processGroup }) ?? false
    }
}
