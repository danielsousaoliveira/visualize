import Foundation

struct DatabaseConnectionSettings: Codable, Hashable, Identifiable, Sendable {
    enum Engine: String, Codable, CaseIterable, Sendable {
        case postgres = "Postgres"
        case sqlite = "SQLite"
    }

    var id = UUID()
    var name = "Local database"
    var engine: Engine = .postgres
    var host = "localhost"
    var port = 5432
    var user = "postgres"
    var database = "postgres"
    var filePath = ""

    func validate() throws {
        if engine == .postgres {
            guard host == "localhost" || host == "127.0.0.1" else {
                throw DatabaseError("Only local databases are supported")
            }
            guard (1...65535).contains(port), !user.isEmpty, !database.isEmpty else {
                throw DatabaseError("Enter a valid port, user and database")
            }
            guard ![user, database].contains(where: { $0.contains("\0") }) else {
                throw DatabaseError("Connection fields cannot contain null bytes")
            }
        } else {
            guard filePath.hasPrefix("/"), !filePath.hasPrefix("/Network/"), !filePath.contains("\0") else {
                throw DatabaseError("Only local databases are supported")
            }
            let url = URL(filePath: filePath).resolvingSymlinksInPath()
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .volumeIsLocalKey])
            guard values.isRegularFile == true, values.volumeIsLocal == true else {
                throw DatabaseError("Choose an existing local SQLite file")
            }
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DatabaseError("Enter a connection name")
        }
    }
}
