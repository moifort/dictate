import Foundation
import Security

/// Where the Anthropic API key lives. Never UserDefaults: its plist is readable by anyone.
nonisolated protocol SecretStore: Sendable {
    func read() -> String?
    /// An empty value removes the secret.
    func write(_ value: String)
}

/// A generic password in the login keychain.
nonisolated struct KeychainSecret: SecretStore {
    var service = (Bundle.main.bundleIdentifier ?? "com.polyforms.dictate") + ".anthropic"
    var account = "api-key"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    func read() -> String? {
        var item: CFTypeRef?
        var search = query
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        guard SecItemCopyMatching(search as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    func write(_ value: String) {
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        if status != errSecSuccess {
            ErrorReporter.capture(
                NSError(domain: NSOSStatusErrorDomain, code: Int(status)),
                "API key could not be saved to the keychain", category: "settings"
            )
        }
    }
}

/// For tests and previews.
nonisolated final class InMemorySecret: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    init(_ value: String? = nil) { self.value = value }

    func read() -> String? {
        lock.withLock { value }
    }

    func write(_ newValue: String) {
        lock.withLock { value = newValue.isEmpty ? nil : newValue }
    }
}
