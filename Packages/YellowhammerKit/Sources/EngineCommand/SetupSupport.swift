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

/// Where the credentials `Setup` reads and writes live, so it never touches the Keychain directly. The
/// real conformance wraps ``KeychainCredentialStore``; a read error means absent.
protocol SetupCredentialStore: Sendable {
    func secret(for reference: CredentialReference) -> String?
    func store(_ secret: String, for reference: CredentialReference) throws
}

/// Wraps ``KeychainCredentialStore`` as a ``SetupCredentialStore``.
struct KeychainSetupCredentialStore: SetupCredentialStore {
    private let store = KeychainCredentialStore()

    func secret(for reference: CredentialReference) -> String? {
        try? store.read(reference)
    }

    func store(_ secret: String, for reference: CredentialReference) throws {
        try store.store(secret, for: reference)
    }
}

/// The outcome of registering local notification permission at setup (OQ9, OQ13). A refusal never
/// fails setup.
enum NotificationRegistration: Sendable {
    case allowed
    case off(reason: String)
}
