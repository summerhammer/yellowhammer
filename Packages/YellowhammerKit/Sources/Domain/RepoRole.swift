/// The declared role of a repository in the product. The vocabulary is open.
public struct RepoRole: RawRepresentable, Hashable, Sendable {
    public static let spec = RepoRole(rawValue: "spec")
    public static let backend = RepoRole(rawValue: "backend")
    public static let mobile = RepoRole(rawValue: "mobile")
    public static let web = RepoRole(rawValue: "web")

    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}
