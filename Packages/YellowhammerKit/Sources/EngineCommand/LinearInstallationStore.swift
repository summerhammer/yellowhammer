import Config
import Domain
import Foundation
import LinearAdapter
import Security
import Synchronization

/// Builds the Installation's `LinearAdapter.LinearTokenStore` (P17.3, ADR-005) from the Keychain and a
/// the installation's own `MachineLock` (Linear Board Connection Ruling, items 3 and 11). Thin glue only: the
/// JSON codec itself lives on `LinearTokenPair` in `LinearAdapter` (`encoded()` / `init(storedJSON:)`),
/// so this type never decodes or encodes anything — it only moves a string between the Keychain and
/// that codec, and wires the refresh lock.
public struct LinearInstallationStore: Sendable {
    public let reference: CredentialReference
    private let customTokenStore: LinearTokenStore?
    private let keychain: KeychainCredentialStore?
    private let machineLock: MachineLock?

    public init(reference: CredentialReference, keychain: KeychainCredentialStore, machineLock: MachineLock) {
        self.reference = reference
        self.customTokenStore = nil
        self.keychain = keychain
        self.machineLock = machineLock
    }

    public init(reference: CredentialReference, tokenStore: LinearTokenStore) {
        self.reference = reference
        self.customTokenStore = tokenStore
        self.keychain = nil
        self.machineLock = nil
    }

    /// An in-memory store for tests: never touches the Keychain or creates lock files.
    public static func inMemory(
        reference: CredentialReference = CredentialReference("keychain:test-install-\(UUID().uuidString)")!,
        initialTokens: LinearTokenPair? = nil
    ) -> LinearInstallationStore {
        let stored = Mutex<LinearTokenPair?>(initialTokens)
        let tokenStore = LinearTokenStore(
            read: { stored.withLock { $0 } },
            write: { pair in stored.withLock { $0 = pair } },
            withRefreshLock: { body in try await body() }
        )
        return LinearInstallationStore(reference: reference, tokenStore: tokenStore)
    }

    /// The seam `LinearAdapter.LinearInstallationTokenSource` is given.
    public var tokenStore: LinearTokenStore {
        if let customTokenStore {
            return customTokenStore
        }
        guard let keychain, let machineLock else {
            fatalError("LinearInstallationStore misconfigured")
        }
        return LinearTokenStore(
            read: { try self.read(keychain: keychain) },
            write: { try self.write($0, keychain: keychain) },
            withRefreshLock: { body in
                do {
                    try await machineLock.withLock(body)
                } catch let error as MachineLockError {
                    if case .bodyFailed(let inner) = error {
                        // Unwrapped, not the lock's own wrapper: LinearInstallationTokenSource pattern-
                        // matches the BoardError it threw (e.g. `.notAuthenticated`), not MachineLockError.
                        throw inner
                    }
                    throw error
                }
            }
        )
    }

    private func read(keychain: KeychainCredentialStore) throws -> LinearTokenPair? {
        let json: String
        do {
            json = try keychain.read(reference)
        } catch {
            if error.status == errSecItemNotFound {
                return nil
            }
            throw error
        }
        return try LinearTokenPair(storedJSON: json)
    }

    private func write(_ pair: LinearTokenPair, keychain: KeychainCredentialStore) throws {
        try keychain.store(pair.encoded(), for: reference)
    }
}
