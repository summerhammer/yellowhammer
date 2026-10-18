import Foundation
import Security

/// Who a legacy login-Keychain item trusts: the applications on its access list that may read the secret
/// without a prompt, and the partition list that lets a process in a partition do the same. Reading it
/// never reads the secret and never prompts (`SecKeychainItemCopyAccess` returns the ACL, not the data).
public struct KeychainItemAccess: Equatable, Sendable {
    /// The partitions Yellowhammer writes and Keychain Access adds: `teamid:` of the Developer ID that signs
    /// `yh` and the app, and the bare `apple:` entry.
    public static let trustedPartitions: Set<String> = ["teamid:A2SJL2N487", "apple:"]
    /// The executable names an item may trust: `yh` and the app itself.
    public static let trustedExecutableNames: Set<String> = ["yh", "Yellowhammer"]

    /// The executable paths the access list names, or nil when it lets any application read the item.
    public var trustedApplicationPaths: [String]?
    /// The partition list's entries, empty when the item has none.
    public var partitions: [String]

    public init(trustedApplicationPaths: [String]?, partitions: [String]) {
        self.trustedApplicationPaths = trustedApplicationPaths
        self.partitions = partitions
    }

    /// What widened the item beyond `yh` / Yellowhammer builds, one phrase each; empty when nothing did.
    public var wideningReasons: [String] {
        var reasons: [String] = []
        if let paths = trustedApplicationPaths {
            let others = paths.filter { !Self.trustedExecutableNames.contains(($0 as NSString).lastPathComponent) }
            if !others.isEmpty {
                reasons.append("its access list also names \(others.map { "\"\($0)\"" }.joined(separator: ", "))")
            }
        } else {
            reasons.append("its access list lets any application read it")
        }
        let otherPartitions = partitions.filter { !Self.trustedPartitions.contains($0) }
        if !otherPartitions.isEmpty {
            let quoted = otherPartitions.map { "\"\($0)\"" }.joined(separator: ", ")
            reasons.append("its partition list also holds \(quoted)")
        }
        return reasons
    }
}

extension KeychainCredentialStore {
    /// Reads who the item for `reference` trusts. Throws `.notAKeychainReference` for a non-`keychain:`
    /// reference and `errSecItemNotFound` when the item is absent.
    public func access(of reference: CredentialReference) throws(KeychainError) -> KeychainItemAccess {
        let prefix = "keychain:"
        guard reference.rawValue.hasPrefix(prefix) else {
            throw KeychainError(account: reference.rawValue, operation: .read, status: nil)
        }
        let account = String(reference.rawValue.dropFirst(prefix.count))
        func failure(_ status: OSStatus) -> KeychainError {
            KeychainError(account: account, operation: .read, status: status)
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var ref: CFTypeRef?
        let found = SecItemCopyMatching(query as CFDictionary, &ref)
        guard found == errSecSuccess, let ref else { throw failure(found) }

        var access: SecAccess?
        let copied = SecKeychainItemCopyAccess(ref as! SecKeychainItem, &access) // swiftlint:disable:this force_cast
        guard copied == errSecSuccess, let access else { throw failure(copied) }

        var list: CFArray?
        let listed = SecAccessCopyACLList(access, &list)
        guard listed == errSecSuccess, let acls = list as? [SecACL] else { throw failure(listed) }
        return Self.parse(acls)
    }

    private static func parse(_ acls: [SecACL]) -> KeychainItemAccess {
        var paths: [String]? = []
        var partitions: [String] = []
        for acl in acls {
            let authorizations = SecACLCopyAuthorizations(acl) as? [String] ?? []
            var applications: CFArray?
            var description: CFString?
            var selector = SecKeychainPromptSelector()
            guard SecACLCopyContents(acl, &applications, &description, &selector) == errSecSuccess else { continue }

            if authorizations.contains("ACLAuthorizationDecrypt") {
                if let applications = applications as? [SecTrustedApplication] {
                    paths? += applications.compactMap(Self.path(of:))
                } else {
                    paths = nil
                }
            }
            if authorizations.contains("ACLAuthorizationPartitionID"), let description {
                partitions += Self.partitions(fromDescription: description as String)
            }
        }
        return KeychainItemAccess(trustedApplicationPaths: paths, partitions: partitions)
    }

    /// A trusted application's data is its executable path, NUL-terminated, then its code requirement.
    private static func path(of application: SecTrustedApplication) -> String? {
        var data: CFData?
        guard SecTrustedApplicationCopyData(application, &data) == errSecSuccess, let data = data as Data? else {
            return nil
        }
        return String(bytes: data.prefix { $0 != 0 }, encoding: .utf8)
    }

    /// The partition list's ACL carries a hex-encoded property list, `{Partitions: [String]}`, as its description.
    static func partitions(fromDescription description: String) -> [String] {
        var bytes = Data()
        var index = description.startIndex
        while index < description.endIndex {
            guard let next = description.index(index, offsetBy: 2, limitedBy: description.endIndex),
                  let byte = UInt8(description[index..<next], radix: 16) else { return [] }
            bytes.append(byte)
            index = next
        }
        let plist = try? PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any]
        return plist?["Partitions"] as? [String] ?? []
    }
}
