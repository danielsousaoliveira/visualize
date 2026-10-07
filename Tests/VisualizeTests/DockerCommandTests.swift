import Foundation
import Testing
@testable import visualize

struct DockerCommandTests {
    @Test func findsSiblingCredentialHelperWithControlledEnvironment() async throws {
        let stub = try StubHelper { _ in
            """
            [ "$1" = --host ] && [ "$2" = unix:///test/docker.sock ] || exit 1
            [ -z "$DOCKER_HOST$DOCKER_CONTEXT$DOCKER_CONFIG$DOCKER_TLS_VERIFY$DOCKER_CERT_PATH" ] || exit 2
            docker-credential-visualize-test
            """
        }
        defer { stub.remove() }
        let helper = stub.file("docker-credential-visualize-test")
        try "#!/bin/sh\nprintf 'helper-found\\n'\n".write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let command = DockerCommand(executable: stub.executable.path, endpoint: "unix:///test/docker.sock")
        let output = try await command.run(["build", "."], directory: stub.directory.path)
        #expect(String(decoding: output, as: UTF8.self) == "helper-found\n")
    }
}
