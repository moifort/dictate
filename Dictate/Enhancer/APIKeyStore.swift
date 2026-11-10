import Foundation
import Security

/// Where an API key lives. Never UserDefaults: its plist is readable by anyone.
nonisolated protocol SecretStore: Sendable {
    /// Nil when no secret is stored; throws when the store could not be read.
    func read() throws -> String?
    /// An empty value removes the secret. Throws when it could not be saved,
    /// leaving the previous one in place.
    func write(_ value: String) throws
}

/// A keychain call that did not succeed.
nonisolated struct KeychainError: LocalizedError, Equatable {
    let status: OSStatus

    var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return String(localized: "Trousseau : \(message)")
    }
}

/// A generic password in the login keychain.
nonisolated struct KeychainSecret: SecretStore {
    /// One service for every provider's key, told apart by the account.
    static func service(for identifier: String = AppIdentity.current) -> String { identifier + ".api-keys" }
    /// Named when only Anthropic had a key; every provider's went there since.
    static func legacyService(for identifier: String = AppIdentity.current) -> String { identifier + ".anthropic" }

    var service = KeychainSecret.service()
    var account: String

    /// This copy's item for `provider`, moved from the legacy service on first read.
    static func apiKey(_ provider: APIProvider) -> SecretStore {
        MovingSecret(
            to: KeychainSecret(service: service(), account: provider.keychainAccount),
            from: KeychainSecret(service: legacyService(), account: provider.keychainAccount)
        )
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    func read() throws -> String? {
        var item: CFTypeRef?
        var search = query
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(search as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw KeychainError(status: status) }
        return String(decoding: data, as: UTF8.self)
    }

    /// Updates the item in place, or adds it: never deletes first, so a failed
    /// save keeps the previous key.
    func write(_ value: String) throws {
        guard !value.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
            return
        }
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }
}

/// A secret moving from an old store to a new one: read from the new one,
/// else taken from the old one, saved in the new and removed from the old.
/// Written and removed in both, so nothing is left behind.
nonisolated struct MovingSecret: SecretStore {
    let to: any SecretStore
    let from: any SecretStore

    func read() throws -> String? {
        if let value = try to.read() { return value }
        guard let old = try from.read(), !old.isEmpty else { return nil }
        try to.write(old)
        try? from.write("")
        return old
    }

    func write(_ value: String) throws {
        try to.write(value)
        try? from.write("")
    }
}

/// For tests and previews.
nonisolated final class InMemorySecret: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    /// Thrown by the next reads and writes, to play a locked keychain.
    var failure: (any Error)?

    init(_ value: String? = nil) { self.value = value }

    func read() throws -> String? {
        try lock.withLock {
            if let failure { throw failure }
            return value
        }
    }

    func write(_ newValue: String) throws {
        try lock.withLock {
            if let failure { throw failure }
            value = newValue.isEmpty ? nil : newValue
        }
    }
}
