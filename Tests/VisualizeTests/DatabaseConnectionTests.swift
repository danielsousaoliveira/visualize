import Foundation
import Testing
@testable import visualize

struct DatabaseConnectionTests {
    @Test func sqliteConnectionRejectsWrites() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "visualize-sqlite-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "fixture.sqlite").path
        let result = try CommandOutput.run("/usr/bin/sqlite3", arguments: [path, "CREATE TABLE entries (id INTEGER); INSERT INTO entries VALUES (1);"])
        #expect(result.status == 0)
        var settings = DatabaseConnectionSettings()
        settings.engine = .sqlite
        settings.filePath = path
        let connection = try DatabaseConnection(settings: settings, password: "")
        #expect(try await connection.version().split(separator: ".").count >= 3)
        #expect(try await connection.execute("SELECT COUNT(*) FROM entries") == "1")
        do {
            _ = try await connection.execute("INSERT INTO entries VALUES (2)")
            Issue.record("SQLite accepted a write")
        } catch { #expect(error.localizedDescription.lowercased().contains("readonly")) }
        #expect(try await connection.execute("SELECT COUNT(*) FROM entries") == "1")
        await connection.close()
    }

    @Test func rejectsNonDatabaseSQLiteFile() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "visualize-not-sqlite-\(UUID())")
        try "This is not a SQLite database".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        var settings = DatabaseConnectionSettings()
        settings.engine = .sqlite
        settings.filePath = file.path
        do {
            _ = try DatabaseConnection(settings: settings, password: "")
            Issue.record("Accepted a file that is not a database")
        } catch { #expect(error.localizedDescription.contains("not a database")) }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VISUALIZE_TEST_POSTGRES_PORT"] != nil))
    func postgresConnectionRejectsWrites() async throws {
        var settings = DatabaseConnectionSettings()
        settings.port = try #require(Int(ProcessInfo.processInfo.environment["VISUALIZE_TEST_POSTGRES_PORT"] ?? ""))
        settings.user = NSUserName()
        let password = ProcessInfo.processInfo.environment["VISUALIZE_TEST_POSTGRES_PASSWORD"] ?? ""
        let connection = try DatabaseConnection(settings: settings, password: password)
        #expect(try await connection.version().contains("PostgreSQL"))
        #expect(try await connection.execute("SHOW default_transaction_read_only") == "on")
        do {
            _ = try await connection.execute("INSERT INTO visualize_read_only_fixture VALUES (2)")
            Issue.record("Postgres accepted a write")
        } catch { #expect(error.localizedDescription.contains("read-only transaction")) }
        #expect(try await connection.execute("SELECT COUNT(*) FROM visualize_read_only_fixture") == "1")
        await connection.close()
    }

    @Test(arguments: ["example.com", "::1", "127.0.0.2", "localhost.example.com", "/tmp", "localhost,example.com", ""])
    func rejectsNonLocalHost(host: String) {
        var settings = DatabaseConnectionSettings()
        settings.host = host
        #expect(throws: DatabaseError.self) { try settings.validate() }
        do { try settings.validate() }
        catch { #expect(error.localizedDescription == "Only local databases are supported") }
    }

    @Test func parsesEnvURLWithoutPersistingCredentialsOrOptions() throws {
        let values = DatabaseDiscovery.envValues("""
        export DATABASE_URL="postgres://alice:s%40cret@localhost:5433/dev?host=example.com&options=bad" # comment
        POSTGRES_URL='postgres://other:literal$secret@127.0.0.1/other'
        """)
        let value = try #require(values["DATABASE_URL"])
        let parsed = try DatabaseCandidate.fromURL(value, source: ".env", directory: URL(filePath: "/tmp"))
        let candidate = try #require(parsed)
        #expect(candidate.settings.host == "localhost")
        #expect(candidate.settings.port == 5433)
        #expect(candidate.settings.user == "alice")
        #expect(candidate.settings.database == "dev")
        #expect(candidate.password == "s@cret")
        let json = String(decoding: try JSONEncoder().encode(candidate.settings), as: UTF8.self)
        #expect(!json.contains("password"))
        #expect(!json.contains("s@cret"))
        #expect(!json.contains("example.com"))
        #expect(throws: DatabaseError.self) {
            try DatabaseCandidate.fromURL("postgres://user:secret@example.com/db", source: ".env", directory: URL(filePath: "/tmp"))
        }
    }

    @Test func parsesComposeEnvironmentAndPublishedPort() throws {
        let data = Data(#"{"services":{"db":{"image":"postgres:16","environment":{"POSTGRES_USER":"dev","POSTGRES_PASSWORD":"secret","POSTGRES_DB":"app"},"ports":[{"target":5432,"published":"55432","protocol":"tcp"}]},"cache":{"image":"redis:7"}}}"#.utf8)
        let candidates = try DatabaseDiscovery.composeCandidates(data, source: "compose.yml")
        #expect(candidates.count == 1)
        let candidate = try #require(candidates.first)
        #expect(candidate.settings.port == 55432)
        #expect(candidate.settings.user == "dev")
        #expect(candidate.settings.database == "app")
        #expect(candidate.password == "secret")
    }

    @Test func resolvesSQLiteEnvPathsLocally() throws {
        let parsed = try DatabaseCandidate.fromURL("file:./data/dev.db", source: ".env", directory: URL(filePath: "/tmp/project"))
        let candidate = try #require(parsed)
        #expect(candidate.settings.engine == .sqlite)
        #expect(candidate.settings.filePath == "/tmp/project/data/dev.db")
        #expect(throws: DatabaseError.self) {
            try DatabaseCandidate.fromURL("file://example.com/data/db", source: ".env", directory: URL(filePath: "/tmp"))
        }
    }

    @Test func connectionMetadataSurvivesLibraryReload() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "visualize-library-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        var project = Project(folder: directory)
        project.databaseConnections = [DatabaseConnectionSettings()]
        let store = ProjectLibraryStore(directory: directory)
        try store.save([project])
        #expect(try store.load().first?.databaseConnections == project.databaseConnections)
        #expect(try !String(contentsOf: store.fileURL, encoding: .utf8).contains("password"))
    }
    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VISUALIZE_TEST_KEYCHAIN"] == "1"))
    func savedConnectionKeepsPasswordOnlyInKeychain() throws {
        let stub = try StubHelper { _ in "exit 0" }
        defer { stub.remove() }
        let store = ProjectLibraryStore(directory: stub.file("support"))
        let project = Project(folder: stub.file("project"))
        try store.save([project])
        let state = AppState(scanHelper: ScanHelper(executableURL: stub.executable), store: store)
        defer { state.listenerStore.stop() }
        var settings = DatabaseConnectionSettings()
        defer { try? DatabasePasswordStore.delete(projectID: project.id, connectionID: settings.id) }
        try state.saveDatabaseConnection(settings, password: "fixture-secret", projectID: project.id)
        #expect(try DatabasePasswordStore.read(projectID: project.id, connectionID: settings.id) == "fixture-secret")
        let json = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(!json.contains("password"))
        #expect(!json.contains("fixture-secret"))
        settings.database = "edited"
        try state.saveDatabaseConnection(settings, password: "replacement-secret", projectID: project.id)
        #expect(try store.load().first?.databaseConnections?.first?.database == "edited")
        #expect(try DatabasePasswordStore.read(projectID: project.id, connectionID: settings.id) == "replacement-secret")
        try state.deleteDatabaseConnection(settings, projectID: project.id)
        #expect(try store.load().first?.databaseConnections?.isEmpty == true)
        #expect(try DatabasePasswordStore.read(projectID: project.id, connectionID: settings.id) == "")
    }

}
