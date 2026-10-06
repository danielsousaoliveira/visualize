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
