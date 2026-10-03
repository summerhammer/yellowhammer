import Config
import Domain

/// A `yh setup` failure, printed as-is and turned into a non-zero exit.
struct SetupError: Error, CustomStringConvertible, Sendable {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var description: String { message }
}

/// Whether an Installation token pair is present in the Keychain, so `Setup`/`Doctor` never touch the
/// Keychain directly for this presence check. The real conformance wraps ``KeychainCredentialStore``; a
/// read error means absent. Presence-only, by design (P17.4): it reads only to test presence — the
/// value itself (opaque JSON, `LinearInstallationStore`'s own concern) is read back but never used here.
protocol SetupCredentialStore: Sendable {
    func secret(for reference: CredentialReference) -> String?
}

/// Wraps ``KeychainCredentialStore`` as a ``SetupCredentialStore``.
struct KeychainSetupCredentialStore: SetupCredentialStore {
    private let store = KeychainCredentialStore()

    func secret(for reference: CredentialReference) -> String? {
        try? store.read(reference)
    }
}

/// The outcome of registering local notification permission at setup (OQ9, OQ13). A refusal never
/// fails setup.
enum NotificationRegistration: Sendable {
    case allowed
    case off(reason: String)
}

/// Deletes an Installation's token pair from the Keychain, so `yh config remove-installation` never
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
