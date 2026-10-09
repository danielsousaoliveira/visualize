import Foundation
import Security

struct DatabasePasswordStore {
    private static let service = "visualize.database"

    private static func query(projectID: UUID, connectionID: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "\(projectID.uuidString)/\(connectionID.uuidString)"]
    }

    static func read(projectID: UUID, connectionID: UUID) throws -> String {
        var query = query(projectID: projectID, connectionID: connectionID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        try check(status)
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw DatabaseError("Could not read database password from Keychain")
        }
        return value
    }

    static func save(_ password: String, projectID: UUID, connectionID: UUID) throws {
        let query = query(projectID: projectID, connectionID: connectionID)
        let attributes: [String: Any] = [kSecValueData as String: Data(password.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query.merging(attributes) { _, new in new }
            item[kSecAttrLabel as String] = "visualize database connection"
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            try check(SecItemAdd(item as CFDictionary, nil))
        } else { try check(status) }
    }

    static func delete(projectID: UUID, connectionID: UUID) throws {
        let status = SecItemDelete(query(projectID: projectID, connectionID: connectionID) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw DatabaseError(SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)")
        }
    }
}
