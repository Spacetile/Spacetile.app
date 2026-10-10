import Foundation
import Security

/// Strings kept as generic passwords in the login keychain, under Spacetile's bundle identifier.
enum Keychain {
    private static let service = "com.kodehort.spacetile"

    static func read(_ account: String) -> String? {
        var query = item(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Adds or replaces the value. Returns false if the keychain refused.
    @discardableResult static func write(_ value: String, to account: String) -> Bool {
        let data = Data(value.utf8)
        var status = SecItemUpdate(item(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = item(account)
            add[kSecValueData as String] = data
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status != errSecSuccess { log.error("keychain: couldn't save \(account, privacy: .public) (\(status))") }
        return status == errSecSuccess
    }

    private static func item(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}
