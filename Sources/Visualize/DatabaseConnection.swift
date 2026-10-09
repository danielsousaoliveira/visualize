import Foundation
import DatabaseDriver

actor DatabaseConnection {
    private var handle: DatabaseHandle?
    let engine: DatabaseConnectionSettings.Engine

    init(settings: DatabaseConnectionSettings, password: String) throws {
        try settings.validate()
        guard !password.contains("\0") else { throw DatabaseError("Password cannot contain null bytes") }
        engine = settings.engine
        var failure: UnsafeMutablePointer<CChar>?
        let pointer: OpaquePointer?
        if settings.engine == .sqlite {
            pointer = vd_sqlite_open(settings.filePath, &failure)
        } else {
            let candidates = ["/opt/homebrew/opt/libpq/lib/libpq.dylib", "/usr/local/opt/libpq/lib/libpq.dylib"]
            let library = candidates.first { FileManager.default.fileExists(atPath: $0) } ?? candidates[0]
            pointer = vd_postgres_open(library, String(settings.port), settings.user, password, settings.database, &failure)
        }
        if let failure {
            defer { vd_free(failure) }
            throw DatabaseError(String(cString: failure).replacingOccurrences(of: password.isEmpty ? "\0" : password, with: "[redacted]"))
        }
        guard let pointer else { throw DatabaseError("Could not open database") }
        handle = DatabaseHandle(pointer)
    }

    func close() {
        handle = nil
    }

    func version() throws -> String {
        try execute(engine == .postgres ? "SELECT version()" : "SELECT sqlite_version()")
    }

    func execute(_ sql: String) throws -> String {
        guard let handle else { throw DatabaseError("Connection is closed") }
        guard !sql.contains("\0") else { throw DatabaseError("Query cannot contain null bytes") }
        var failure: UnsafeMutablePointer<CChar>?
        let result = vd_query(handle.pointer, sql, &failure)
        if let failure {
            defer { vd_free(failure) }
            throw DatabaseError(String(cString: failure))
        }
        guard let result else { throw DatabaseError("Query returned no result") }
        defer { vd_free(result) }
        return String(cString: result)
    }
}
