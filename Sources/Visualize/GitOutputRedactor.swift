import Foundation

enum GitOutputRedactor {
    static func redact(_ text: String) -> String {
        let userInfo = text.replacingOccurrences(
            of: #"(?i)([a-z][a-z0-9+.-]*://)[^\s/]+@"#,
            with: "$1[redacted]@",
            options: .regularExpression
        )
        let urls = userInfo.replacingOccurrences(
            of: #"(?i)([a-z][a-z0-9+.-]*://[^\s\"'<>?#]+)[?#][^\s\"'<>]*"#,
            with: "$1[redacted]",
            options: .regularExpression
        )
        return urls.replacingOccurrences(
            of: #"([?&][a-z0-9_.~-]+=)[^\s\"'<>]*"#,
            with: "$1[redacted]",
            options: [.regularExpression, .caseInsensitive]
        )
    }
}
