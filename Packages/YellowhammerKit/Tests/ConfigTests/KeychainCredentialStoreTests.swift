import Config
import Foundation
import Testing

@Suite(.serialized)
struct KeychainCredentialStoreTests {
    private func credential(_ string: String) throws -> CredentialReference {
        try #require(CredentialReference(string))
    }

    @Test("A stored secret is read back under the same reference")
    func storeThenRead() throws {
        let store = KeychainCredentialStore()
        let reference = try credential("keychain:test-\(UUID().uuidString)")
        defer { try? store.store("", for: reference) }

        try store.store("s3cr3t", for: reference)
        #expect(try store.read(reference) == "s3cr3t")
    }

    @Test("Storing again for the same reference replaces the previous secret")
    func storeReplacesExisting() throws {
        let store = KeychainCredentialStore()
        let reference = try credential("keychain:test-\(UUID().uuidString)")
        defer { try? store.store("", for: reference) }

        try store.store("first", for: reference)
        try store.store("second", for: reference)
        #expect(try store.read(reference) == "second")
    }

    @Test("Reading an account with nothing stored throws")
    func readMissingThrows() throws {
        let store = KeychainCredentialStore()
        let reference = try credential("keychain:test-\(UUID().uuidString)")

        #expect(throws: KeychainError.self) {
            try store.read(reference)
        }
    }

    @Test("A reference without the keychain: scheme throws without touching the Keychain")
    func nonKeychainReferenceThrows() throws {
        let store = KeychainCredentialStore()
        let reference = try credential("plaintext:not-a-keychain-reference")

        #expect(throws: KeychainError.self) {
            try store.read(reference)
        }
    }
}
