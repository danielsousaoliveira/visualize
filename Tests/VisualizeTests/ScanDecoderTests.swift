import Foundation
import Testing
@testable import visualize

struct ScanDecoderTests {
    static let goldenDirectory = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .appending(path: "../../scan-helper/test/golden")
        .standardizedFileURL

    static let goldenFiles: [URL] = (try? FileManager.default.contentsOfDirectory(
        at: goldenDirectory,
        includingPropertiesForKeys: nil
    ))?.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []

    @Test func goldenOutputsExist() {
        #expect(Self.goldenFiles.count >= 14)
    }

    @Test func decodesDevCommands() throws {
        let url = Self.goldenDirectory.appending(path: "scan-pnpm-workspace.json")
        let result = try ScanDecoder.decode(Data(contentsOf: url))
        #expect(result.services.map(\.devCommand) == [
            ScanDevCommand(argv: ["pnpm", "run", "dev"], workingDirectory: "apps/web", source: "script:dev"),
            ScanDevCommand(argv: ["pnpm", "run", "start"], workingDirectory: "apps/api", source: "script:start"),
        ])
    }

    @Test func decodesAMissingDevCommandAsNil() throws {
        let url = Self.goldenDirectory.appending(path: "scan-compose-env.json")
        let result = try ScanDecoder.decode(Data(contentsOf: url))
        let db = try #require(result.services.first { $0.name == "db" })
        #expect(db.devCommand == nil)
    }

    @Test(arguments: goldenFiles)
    func decodesGoldenOutput(_ url: URL) throws {
        let result = try ScanDecoder.decode(Data(contentsOf: url))
        #expect(result.schemaVersion == 1)
        #expect(!result.project.name.isEmpty)
        #expect(!result.services.isEmpty)
    }

    @Test func decodesComposeServices() throws {
        let url = Self.goldenDirectory.appending(path: "scan-compose-env.json")
        let result = try ScanDecoder.decode(Data(contentsOf: url))
        #expect(result.project.type == .services)
        #expect(result.services.map(\.id) == ["compose:api", "compose:db", "compose:cache"])
        let db = try #require(result.composeServices.first { $0.name == "db" })
        #expect(db.image == "postgres:16")
        #expect(db.ports == [ScanPortMapping(host: "5432", container: "5432")])
        #expect(db.environment == ["POSTGRES_PASSWORD", "POSTGRES_USER"])
    }

    @Test func decodesInfra() throws {
        let url = Self.goldenDirectory.appending(path: "scan-compose-env.json")
        let result = try ScanDecoder.decode(Data(contentsOf: url))
        #expect(result.infra == [
            ScanInfra(
                id: "infra:postgres",
                kind: .postgres,
                usedBy: ["compose:api"],
                providedBy: "compose:db",
                evidence: ["image postgres:16 in compose service db", "env DATABASE_URL in compose service api"],
                host: "db",
                port: 5432
            ),
            ScanInfra(
                id: "infra:redis",
                kind: .redis,
                usedBy: [],
                providedBy: "compose:cache",
                evidence: ["image redis:7 in compose service cache"],
                host: nil,
                port: nil
            ),
        ])
    }

    @Test func decodesConnections() throws {
        let url = Self.goldenDirectory.appending(path: "scan-connections-workspace.json")
        let result = try ScanDecoder.decode(Data(contentsOf: url))
        #expect(result.connections == [
            ScanConnection(from: "apps/web", to: "apps/api", kind: .envURL, label: "NEXT_PUBLIC_API_URL"),
            ScanConnection(from: "apps/web", to: "apps/api", kind: .workspaceDep, label: "api"),
            ScanConnection(from: "apps/api", to: "infra:postgres", kind: .usesInfra, label: "postgres"),
        ])
    }

    @Test func decodesDependsOnConnections() throws {
        let url = Self.goldenDirectory.appending(path: "scan-compose-env.json")
        let result = try ScanDecoder.decode(Data(contentsOf: url))
        #expect(result.connections.filter { $0.kind == .dependsOn }.map(\.to) == ["compose:db", "compose:cache"])
    }

    @Test func decodesInfraWithoutACompose() throws {
        let url = Self.goldenDirectory.appending(path: "scan-infra-redis-env.json")
        let result = try ScanDecoder.decode(Data(contentsOf: url))
        let redis = try #require(result.infra.first)
        #expect(redis.kind == .redis)
        #expect(redis.providedBy == nil)
        #expect(redis.host == "localhost")
        #expect(redis.port == 6380)
    }

    @Test func decodesEnvRequirements() throws {
        let url = Self.goldenDirectory.appending(path: "scan-env-requirements.json")
        let result = try ScanDecoder.decode(Data(contentsOf: url))
        let requirement = try #require(result.envRequirements.first)
        #expect(requirement.serviceId == ".")
        #expect(requirement.variables.map(\.status) == [.set, .missing, .missing, .extra, .set])
        #expect(requirement.variables.first == ScanEnvVariable(name: "A", status: .set, declaredIn: [".env.example", ".env"]))
    }

    @Test func rejectsANewerSchemaVersion() throws {
        let url = Self.goldenDirectory.appending(path: "deploy-node.json")
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object["schemaVersion"] = 2
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: ScanDecodingError.unsupportedVersion(2)) {
            try ScanDecoder.decode(data)
        }
    }

    @Test func rejectsVersionTwoEvenWhenTheShapeChanged() {
        let data = Data(#"{"schemaVersion": 2, "projects": []}"#.utf8)
        #expect(throws: ScanDecodingError.unsupportedVersion(2)) {
            try ScanDecoder.decode(data)
        }
    }

    @Test func rejectsOutputWithoutAVersion() {
        let data = Data(#"{"project": {}}"#.utf8)
        #expect(throws: ScanDecodingError.malformed("missing integer schemaVersion")) {
            try ScanDecoder.decode(data)
        }
    }

    @Test func describesTheUnsupportedVersionAsAnUpdate() {
        let message = ScanDecodingError.unsupportedVersion(2).localizedDescription
        #expect(message.contains("Unsupported scan version 2"))
        #expect(message.contains("Update visualize"))
    }
}
