import Foundation

enum ScanDecoder {
    static let supportedSchemaVersion = 1

    static func decode(_ data: Data) throws -> ScanResult {
        let version = try schemaVersion(in: data)
        guard version == supportedSchemaVersion else {
            throw ScanDecodingError.unsupportedVersion(version)
        }
        do {
            return try JSONDecoder().decode(ScanResult.self, from: data)
        } catch {
            throw ScanDecodingError.malformed(String(describing: error))
        }
    }

    private static func schemaVersion(in data: Data) throws -> Int {
        let object = try? JSONSerialization.jsonObject(with: data)
        guard let version = (object as? [String: Any])?["schemaVersion"] as? Int else {
            throw ScanDecodingError.malformed("missing integer schemaVersion")
        }
        return version
    }
}
