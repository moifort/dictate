import Foundation
import Security
import Testing

@testable import Dictate

/// Against the real login keychain, under a service of its own. Skipped
/// where the keychain is locked, as on a CI runner.
@Suite(.enabled(if: TestKeychain.isUsable))
struct KeychainSecretTests {
    private let secret = KeychainSecret(service: TestKeychain.service, account: "test-\(UUID().uuidString)")

    @Test func aMissingSecretReadsAsNil() throws {
        #expect(try secret.read() == nil)
    }

    @Test func aSecretIsSavedReplacedAndRemoved() throws {
        defer { try? secret.write("") }
        try secret.write("first")
        #expect(try secret.read() == "first")
        try secret.write("second")
        #expect(try secret.read() == "second")
        try secret.write("")
        #expect(try secret.read() == nil)
        // Removing what is not there is no error.
        try secret.write("")
    }
}

nonisolated enum TestKeychain {
    static let service = "com.thibautmottet.dictate.tests.keychain"

    static var isUsable: Bool {
        let probe = KeychainSecret(service: service, account: "probe-\(UUID().uuidString)")
        defer { try? probe.write("") }
        return (try? probe.write("probe")) != nil && (try? probe.read()) == "probe"
    }
}

/// The keys move from the service named after Anthropic to the shared one.
struct MovingSecretTests {
    @Test func aKeyLeftInTheOldServiceMovesOnFirstRead() throws {
        let new = InMemorySecret()
        let old = InMemorySecret("sk-old")
        let secret = MovingSecret(to: new, from: old)
        #expect(try secret.read() == "sk-old")
        #expect(try new.read() == "sk-old")
        #expect(try old.read() == nil)
    }

    @Test func theNewServiceWins() throws {
        let secret = MovingSecret(to: InMemorySecret("sk-new"), from: InMemorySecret("sk-old"))
        #expect(try secret.read() == "sk-new")
    }

    @Test func savingOrRemovingClearsTheOldService() throws {
        let new = InMemorySecret()
        let old = InMemorySecret("sk-old")
        try MovingSecret(to: new, from: old).write("")
        #expect(try old.read() == nil)
        #expect(try new.read() == nil)
    }

    @Test func theServiceNoLongerNamesAnthropic() {
        #expect(KeychainSecret.service(for: "a.b") == "a.b.api-keys")
        #expect(KeychainSecret.legacyService(for: "a.b") == "a.b.anthropic")
    }
}
