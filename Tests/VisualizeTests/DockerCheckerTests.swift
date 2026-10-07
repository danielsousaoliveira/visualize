import Foundation
import Testing
@testable import visualize

struct DockerCheckerTests {
    @Test func reportsMissingCLI() async {
        let state = await DockerChecker(searchPaths: []).check(overridePath: "/nonexistent/docker")
        #expect(state == .cliNotFound)
        #expect(state.unavailableReason() == "Docker CLI not found")
    }

    @Test func stopsHungDockerAfterFiveSeconds() async throws {
        let stub = try StubHelper { dir in
            """
            echo $$ > '\(dir.path)/pid'
            trap '' TERM
            exec sleep 60
            """
        }
        defer { stub.remove() }
        let start = Date()
        let state = await DockerChecker(searchPaths: []).check(overridePath: stub.executable.path)
        #expect(state == .notRunning)
        #expect(Date().timeIntervalSince(start) >= 5)
        #expect(Date().timeIntervalSince(start) < 7)
        let pidText = try String(contentsOf: stub.file("pid"), encoding: .utf8)
        let pid = try #require(pid_t(pidText.trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(kill(pid, 0) == -1)
    }

    @Test func missingComposeDisablesOnlyCompose() async throws {
        let stub = try StubHelper { _ in
            """
            if [ "$1" = context ]; then
                if [ "$2" = show ]; then echo default; else echo '"unix:///var/run/docker.sock"'; fi
                exit 0
            fi
            shift 2
            if [ "$1" = info ]; then
                echo '{"OperatingSystem":"OrbStack","Name":"orbstack"}'
            else
                exit 1
            fi
            """
        }
        defer { stub.remove() }
        let state = await DockerChecker(searchPaths: []).check(overridePath: stub.executable.path)
        #expect(state == .running(provider: "OrbStack", composeAvailable: false))
        #expect(state.unavailableReason() == nil)
        #expect(state.unavailableReason(compose: true) == "Docker Compose v2 plugin is missing")
    }

    @Test func refusesRemoteContextBeforeCheckingDaemon() async throws {
        let stub = try StubHelper { dir in
            """
            if [ "$1" = context ]; then
                if [ "$2" = show ]; then echo remote; else echo '"tcp://example.com:2375"'; fi
            else
                touch '\(dir.path)/connected'
            fi
            """
        }
        defer { stub.remove() }
        let state = await DockerChecker(searchPaths: []).check(overridePath: stub.executable.path)
        #expect(state == .notRunning)
        #expect(!FileManager.default.fileExists(atPath: stub.file("connected").path))
    }

    @Test func usesOnlyLocalEndpointAndControlledEnvironment() async throws {
        let stub = try StubHelper { _ in
            """
            [ -z "$DOCKER_HOST$DOCKER_CONTEXT$DOCKER_CONFIG$DOCKER_TLS_VERIFY$DOCKER_CERT_PATH" ] || exit 1
            if [ "$1" = context ]; then
                if [ "$2" = show ]; then echo desktop-linux; else echo '"unix:///var/run/docker.sock"'; fi
                exit 0
            fi
            [ "$1" = --host ] && [ "$2" = unix:///var/run/docker.sock ] || exit 1
            case "$3" in
                info) echo '{"OperatingSystem":"Linux","Name":"docker"}' ;;
                compose) echo 2.39.0 ;;
            esac
            """
        }
        defer { stub.remove() }
        let state = await DockerChecker(searchPaths: []).check(overridePath: stub.executable.path)
        #expect(state == .running(provider: "Docker Desktop", composeAvailable: true))
    }

    @Test(arguments: [("Docker Desktop", "desktop", "Docker Desktop"), ("Linux", "colima", "Colima"), ("Linux", "server", "Other")])
    func identifiesProviderAndCompose(os: String, name: String, expected: String) async throws {
        let stub = try StubHelper { _ in
            """
            if [ "$1" = context ]; then
                if [ "$2" = show ]; then echo default; else echo '"unix:///var/run/docker.sock"'; fi
                exit 0
            fi
            shift 2
            case "$1" in
                info) echo '{"OperatingSystem":"\(os)","Name":"\(name)"}' ;;
                context) echo default ;;
                compose) echo 2.39.0 ;;
            esac
            """
        }
        defer { stub.remove() }
        let state = await DockerChecker(searchPaths: []).check(overridePath: stub.executable.path)
        #expect(state == .running(provider: expected, composeAvailable: true))
    }
}
