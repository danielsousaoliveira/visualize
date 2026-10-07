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

    @Test(arguments: [("Docker Desktop", "desktop", "Docker Desktop"), ("Linux", "colima", "Colima"), ("Linux", "server", "Other")])
    func identifiesProviderAndCompose(os: String, name: String, expected: String) async throws {
        let stub = try StubHelper { _ in
            """
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
