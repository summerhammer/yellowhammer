import Foundation
import Security

/// Resolves a `CredentialReference` of the form `keychain:<account>` to the secret stored in the
/// macOS login keychain, and writes secrets there under the same convention. The configuration
/// file holds only the reference; the secret itself never appears in a config file or in the repo.
public struct KeychainCredentialStore: Sendable {
    /// Shared by every process that reads Yellowhammer's credentials (the app and `yh`), so both
    /// resolve the same reference to the same item.
    public static let service = "dev.yellowhammer"

    public init() {}

    /// Fetches the secret for `reference`. Throws `.notAKeychainReference` if the reference does
    /// not use the `keychain:` scheme.
    public func read(_ reference: CredentialReference) throws(KeychainError) -> String {
        let account = try account(for: reference)

        var query = Self.query(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            throw KeychainError(account: account, operation: .read, status: status)
        }
        guard let data = result as? Data, let secret = String(data: data, encoding: .utf8) else {
            throw KeychainError(account: account, operation: .read, status: errSecDecode)
        }
        return secret
    }

    /// Stores `secret` for `reference`, replacing any existing item under the same account.
    public func store(_ secret: String, for reference: CredentialReference) throws(KeychainError) {
        let account = try account(for: reference)
        let data = Data(secret.utf8)

        var query = Self.query(account: account)
        let attributes: [String: Any] = [kSecValueData as String: data]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            query[kSecValueData as String] = data
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError(account: account, operation: .store, status: addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw KeychainError(account: account, operation: .store, status: updateStatus)
        }
    }

    /// Deletes the item for `reference`. An item that is already absent counts as deleted
    /// (`errSecItemNotFound`), so a repeated removal is idempotent.
    public func delete(_ reference: CredentialReference) throws(KeychainError) {
        let account = try account(for: reference)
        let status = SecItemDelete(Self.query(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(account: account, operation: .delete, status: status)
        }
    }

    private func account(for reference: CredentialReference) throws(KeychainError) -> String {
        let prefix = "keychain:"
        guard reference.rawValue.hasPrefix(prefix) else {
            throw KeychainError(account: reference.rawValue, operation: .read, status: nil)
        }
        return String(reference.rawValue.dropFirst(prefix.count))
    }

    private static func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

/// A Keychain operation that could not complete, identified by account and the underlying
/// `OSStatus`. `status == nil` means the reference did not use the `keychain:` scheme at all.
public struct KeychainError: Error, Equatable, Sendable {
    public enum Operation: Equatable, Sendable {
        case read
        case store
        case delete
    }

    public let account: String
    public let operation: Operation
    public let status: OSStatus?

    public init(account: String, operation: Operation, status: OSStatus?) {
        self.account = account
        self.operation = operation
        self.status = status
    }
}

extension KeychainError: CustomStringConvertible {
    public var description: String {
        guard let status else {
            return "\"\(account)\" is not a keychain: reference"
        }
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        switch operation {
        case .read:
            return "could not read Keychain item \"\(account)\": \(message)"
        case .store:
            return "could not store Keychain item \"\(account)\": \(message)"
        case .delete:
            return "could not delete Keychain item \"\(account)\": \(message)"
        }
    }
}
