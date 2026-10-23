import Foundation
import Security

/// Minimal Keychain wrapper for API keys.
enum Keychain {
    private static let service = "com.filip.halo"

    static func set(_ value: String?, for account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard let value, !value.isEmpty, let data = value.data(using: .utf8) else { return }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Thread-safe holder so networking code can read the key without touching the main actor.
final class KeyStore: @unchecked Sendable {
    static let shared = KeyStore()
    private let lock = NSLock()
    private var cachedAPIKey: String?
    private var cachedManagementKey: String?

    private init() {
        cachedAPIKey = Keychain.get("openrouter.apiKey")
        cachedManagementKey = Keychain.get("openrouter.managementKey")
    }

    var apiKey: String? {
        get { lock.lock(); defer { lock.unlock() }; return cachedAPIKey }
        set {
            lock.lock(); cachedAPIKey = newValue; lock.unlock()
            Keychain.set(newValue, for: "openrouter.apiKey")
        }
    }

    var managementKey: String? {
        get { lock.lock(); defer { lock.unlock() }; return cachedManagementKey }
        set {
            lock.lock(); cachedManagementKey = newValue; lock.unlock()
            Keychain.set(newValue, for: "openrouter.managementKey")
        }
    }
}
