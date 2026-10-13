/// The declared role of a repository in the product. The vocabulary is open.
public struct RepoRole: RawRepresentable, Hashable, Sendable {
    public static let spec = RepoRole(rawValue: "spec")
    public static let backend = RepoRole(rawValue: "backend")
    public static let mobile = RepoRole(rawValue: "mobile")
    public static let web = RepoRole(rawValue: "web")

    /// The built-in Repo Roles every Mac offers, whatever the Operator has declared.
    public static let standard: [RepoRole] = [.spec, .backend, .mobile, .web]

    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Whether this is one of the built-in ``standard`` Repo Roles.
    public var isStandard: Bool {
        Self.standard.contains(self)
    }

    /// Whether `name` is a Repo Role name the app lets an Operator declare: `^[a-z0-9][a-z0-9_-]*$`. The TOML
    /// decoder enforces it for the machine file's `repo_roles` only; a Repo's own `role` stays free-form.
    public static func isValidName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, isNameAlphanumeric(first) else { return false }
        return name.unicodeScalars.allSatisfy { isNameAlphanumeric($0) || $0 == "_" || $0 == "-" }
    }

    private static func isNameAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar)
    }
}
