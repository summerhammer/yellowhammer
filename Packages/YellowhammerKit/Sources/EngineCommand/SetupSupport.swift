import Config
import Domain
import Security

/// A `yh setup` failure, printed as-is and turned into a non-zero exit.
struct SetupError: Error, CustomStringConvertible, Sendable {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var description: String { message }
}

/// Reads and writes the Keychain on behalf of `Setup` and `Doctor`, so neither touches the Keychain
/// directly. The real conformance wraps ``KeychainCredentialStore``; a read error in ``secret(for:)`` means
/// absent.
///
/// The two callers use it differently:
/// - The Linear steps use it for **presence only** (P17.4): they read an Installation token pair to test
///   that it is there and never use the value (opaque JSON, `LinearInstallationStore`'s own concern).
/// - The GitHub steps **read the token** to call GitHub with it (the credential check), and ``store(_:for:)``
///   puts a token the Operator supplied under its reference. The token is never printed, logged, or stored
///   anywhere but the Keychain.
protocol SetupCredentialStore: Sendable {
    func secret(for reference: CredentialReference) -> String?
    /// Whether the item is there, distinguishing "absent" from "present but could not be read" (a locked
    /// Keychain). The default derives from ``secret(for:)``, which cannot tell the two apart.
    func presence(of reference: CredentialReference) -> CredentialPresence
    /// Stores `secret` under `reference`, replacing any existing item.
    func store(_ secret: String, for reference: CredentialReference) throws
}

/// The answer of ``SetupCredentialStore/presence(of:)``. Never carries the secret.
enum CredentialPresence: Equatable, Sendable {
    case present
    case absent
    /// The item may exist but the read failed (locked Keychain, interaction not allowed, …).
    case unreadable(String)
}

extension SetupCredentialStore {
    func presence(of reference: CredentialReference) -> CredentialPresence {
        secret(for: reference) != nil ? .present : .absent
    }
}

/// Wraps ``KeychainCredentialStore`` as a ``SetupCredentialStore``.
struct KeychainSetupCredentialStore: SetupCredentialStore {
    private let keychain = KeychainCredentialStore()

    func secret(for reference: CredentialReference) -> String? {
        try? keychain.read(reference)
    }

    func presence(of reference: CredentialReference) -> CredentialPresence {
        do {
            _ = try keychain.read(reference)
            return .present
        } catch {
            if error.status == errSecItemNotFound { return .absent }
            return .unreadable("\(error)")
        }
    }

    func store(_ secret: String, for reference: CredentialReference) throws {
        try keychain.store(secret, for: reference)
    }
}

/// The outcome of registering local notification permission at setup (OQ9, OQ13). A refusal never
/// fails setup.
enum NotificationRegistration: Sendable {
    case allowed
    case off(reason: String)
}

/// Deletes an Installation's token pair from the Keychain, so `yh config remove-board-connection` never
/// touches the Keychain directly. An item that is already absent counts as deleted. The real conformance
/// wraps ``KeychainCredentialStore``.
protocol InstallationCredentialDeleter: Sendable {
    func delete(_ reference: CredentialReference) throws
}

/// Wraps ``KeychainCredentialStore`` as an ``InstallationCredentialDeleter``.
struct KeychainInstallationCredentialDeleter: InstallationCredentialDeleter {
    private let store = KeychainCredentialStore()

    func delete(_ reference: CredentialReference) throws {
        try store.delete(reference)
    }
}
