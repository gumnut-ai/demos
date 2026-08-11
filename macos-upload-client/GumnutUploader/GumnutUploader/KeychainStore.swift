import Foundation
import Security

/// API keys live in the login keychain, never in the database or a file.
/// Keys are stored per server (the keychain account is the server URL),
/// because every server has its own key.
enum KeychainStore {
    private static let service = "ai.gumnut.demos.GumnutUploader"
    /// Pre-per-server storage slot; migrated on first read.
    private static let legacyAccount = "gumnut-api-key"

    static func loadAPIKey(server: String) -> String? {
        if let key = load(account: server) {
            return key
        }
        // Migrate a key saved before keys were per-server: it belonged to
        // whatever server is configured now.
        if let legacy = load(account: legacyAccount) {
            save(legacy, account: server)
            delete(account: legacyAccount)
            return legacy
        }
        return nil
    }

    @discardableResult
    static func saveAPIKey(_ key: String, server: String) -> Bool {
        if key.isEmpty {
            delete(account: server)
            return true
        }
        return save(key, account: server)
    }

    // MARK: - Keychain plumbing

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func load(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    private static func save(_ key: String, account: String) -> Bool {
        let data = Data(key.utf8)
        let update = SecItemUpdate(
            baseQuery(account: account) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if update == errSecItemNotFound {
            var add = baseQuery(account: account)
            add[kSecValueData as String] = data
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return update == errSecSuccess
    }

    private static func delete(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }
}
