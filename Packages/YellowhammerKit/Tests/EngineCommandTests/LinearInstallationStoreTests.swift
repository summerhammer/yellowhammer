import Config
@testable import EngineCommand
import Foundation
import Testing

/// Deliberately does not `import LinearAdapter` (MB2: only EngineCommand itself, and an adapter's own
/// test target, may import an adapter). This exercises only the missing-item → nil behaviour, which
/// `#expect(... == nil)` can assert without ever naming `LinearTokenPair` in source.
@Suite("LinearInstallationStore: the Keychain side only (P17.4, ADR-005)")
struct LinearInstallationStoreKeychainTests {
    @Test("Nothing stored: read returns nil, not a throw")
    func missingItemIsNil() throws {
        let reference = try #require(CredentialReference("keychain:test-linear-token-\(UUID().uuidString)"))
        let lockPath = FileManager.default.temporaryDirectory
            .appending(component: "yh-linear-lock-\(UUID().uuidString).lock", directoryHint: .notDirectory)
        let installationStore = LinearInstallationStore(
            reference: reference, keychain: KeychainCredentialStore(), machineLock: MachineLock(fileURL: lockPath)
        )

        #expect(try installationStore.tokenStore.read() == nil)
    }
}
