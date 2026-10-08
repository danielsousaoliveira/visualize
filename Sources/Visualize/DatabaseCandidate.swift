import Foundation

struct DatabaseCandidate: Identifiable, Sendable {
    var settings: DatabaseConnectionSettings
    var password: String
    var source: String
    var id: UUID { settings.id }

    static func fromURL(_ value: String, source: String, directory: URL) throws -> Self? {
        if value.hasPrefix("file:") || value.hasPrefix("sqlite:") {
            let path: String
            if value.hasPrefix("file:") {
                if value.hasPrefix("file://"), let url = URL(string: value) {
                    guard url.host == nil || url.host == "" || url.host == "localhost" else {
                        throw DatabaseError("Only local databases are supported")
                    }
                    path = url.path.removingPercentEncoding ?? url.path
                } else {
                    path = String(value.dropFirst(5)).components(separatedBy: "?")[0].removingPercentEncoding ?? ""
                }
            } else {
                guard let parts = URLComponents(string: value), parts.host == nil || parts.host == "" || parts.host == "localhost" else {
                    throw DatabaseError("Only local databases are supported")
                }
                path = parts.path
            }
            var settings = DatabaseConnectionSettings()
            settings.name = source
            settings.engine = .sqlite
            settings.filePath = path.hasPrefix("/") ? path : directory.appending(path: path).standardizedFileURL.path
            return Self(settings: settings, password: "", source: source)
        }
        guard let parts = URLComponents(string: value), ["postgres", "postgresql"].contains(parts.scheme) else { return nil }
        var settings = DatabaseConnectionSettings()
        settings.name = source
        settings.host = parts.host ?? ""
        settings.port = parts.port ?? 5432
        settings.user = parts.user ?? "postgres"
        settings.database = String(parts.path.dropFirst())
        try settings.validate()
        return Self(settings: settings, password: parts.password ?? "", source: source)
    }
}
