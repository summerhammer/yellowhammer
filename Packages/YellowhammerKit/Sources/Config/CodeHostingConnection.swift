/// One Code Hosting Connection in the machine file's registry (`[code_hosting.github.connections.<name>]`):
/// a way to reach Code Hosting (in v1, GitHub), by the Operator's own `gh` CLI or by a token held in the
/// macOS Keychain. Each Project selects exactly one by ``name``. The file never holds a token, only a
/// Credential Reference to it.
public struct CodeHostingConnection: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// `type = "gh"`: the Operator's own `gh` CLI; holds no token. `executable` is a declared absolute
        /// path to `gh`; nil means it is looked up at the time of use.
        case githubCLI(executable: String?)
        /// `type = "keychain"`: a token held in the macOS Keychain under this Credential Reference.
        case keychainToken(CredentialReference)
    }

    /// The local name, the table key. Chosen by the Operator; not a GitHub identifier.
    public var name: String
    public var kind: Kind

    public init(name: String, kind: Kind) {
        self.name = name
        self.kind = kind
    }

    /// The name `yh setup`'s GitHub step connects a Keychain token under when given none: `github`, whose
    /// Credential Reference is `keychain:github` (``defaultCredentialReference(for:)``).
    public static let defaultName = "github"

    /// The local name a `gh` CLI connection is offered under when the Operator picks it in `yh setup`.
    public static let gitHubCLIDefaultName = "gh"

    /// `keychain:<name>` — the reference a new Keychain token connection is stored under.
    public static func defaultCredentialReference(for name: String) -> CredentialReference {
        // Non-empty literal prefix: never fails.
        CredentialReference("keychain:\(name)")!
    }
}
