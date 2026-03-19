import Foundation
import Security

enum AIProviderKeychain {
    static let pendingMigrationKey = "ideas.pending_ai_provider_key_migration"

    private static let service = (Bundle.main.bundleIdentifier ?? "ideas") + ".ai-provider-key"
    private static let account = "default"

    static func apiKey() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return ""
        }
        return value
    }

    @discardableResult
    static func setAPIKey(_ apiKey: String) -> Bool {
        if apiKey.isEmpty {
            return clearAPIKey()
        }

        guard let data = apiKey.data(using: .utf8) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }

        let addQuery: [String: Any] = query.merging(attributes) { _, new in new }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        return addStatus == errSecSuccess
    }

    @discardableResult
    static func clearAPIKey() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    static func consumePendingMigrationValue() {
        let defaults = UserDefaults.standard
        guard let apiKey = defaults.string(forKey: pendingMigrationKey), !apiKey.isEmpty else {
            defaults.removeObject(forKey: pendingMigrationKey)
            return
        }

        _ = setAPIKey(apiKey)
        defaults.removeObject(forKey: pendingMigrationKey)
    }
}
