import Foundation
import Security

/// The XTB login lives in the keychain under service "xtb-widget": the account is the username,
/// the secret is the password. The password is read only when the page actually asks for a login.
enum Keychain {
    private static let service = "xtb-widget"

    private static func base(_ account: String?) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }

    /// The saved username. Reads attributes only, so macOS does not ask for permission.
    static func username() -> String? {
        var query = base(nil)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let items = out as? [[String: Any]] else { return nil }
        // "fingerprint" is a leftover entry of the early command-line experiment, not a login.
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.first { $0 != "fingerprint" }
    }

    static func password(for username: String) -> String? {
        var query = base(username)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(username: String, password: String) {
        if let old = Self.username() { SecItemDelete(base(old) as CFDictionary) }
        var item = base(username)
        item[kSecValueData as String] = Data(password.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }
}
