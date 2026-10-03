import Config
import Domain
import Foundation
import LinearAdapter
import Security

/// Builds the Installation's `LinearAdapter.LinearTokenStore` (P17.3, ADR-005) from the Keychain and a
/// the installation's own `MachineLock` (Linear App Installation Ruling, items 3 and 11). Thin glue only: the
/// JSON codec itself lives on `LinearTokenPair` in `LinearAdapter` (`encoded()` / `init(storedJSON:)`),
/// so this type never decodes or encodes anything — it only moves a string between the Keychain and
/// that codec, and wires the refresh lock.
public struct LinearInstallationStore: Sendable {
    public let reference: CredentialReference
    private let keychain: KeychainCredentialStore
    private let machineLock: MachineLock

    public init(reference: CredentialReference, keychain: KeychainCredentialStore, machineLock: MachineLock) {
        self.reference = reference
        self.keychain = keychain
        self.machineLock = machineLock
    }

    /// The seam `LinearAdapter.LinearInstallationTokenSource` is given.
    public var tokenStore: LinearTokenStore {
        LinearTokenStore(
            read: { try self.read() },
            write: { try self.write($0) },
            withRefreshLock: { body in
                do {
                    try await self.machineLock.withLock(body)
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

    private func read() throws -> LinearTokenPair? {
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

    private func write(_ pair: LinearTokenPair) throws {
        try keychain.store(pair.encoded(), for: reference)
    }
}
