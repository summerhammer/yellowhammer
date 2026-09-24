import Foundation

/// A link that opens the app scoped to one Project: `yellowhammer://project/<id>` (OQ52 Face 2;
/// ooux/nav-flow → Multi-Project Navigation).
///
/// It names a Project and nothing else — no screen, no Night, no status — because the app's windows
/// are scoped by Project alone. `url` and `init?(url:)` are the contract.
public struct ProjectDeepLink: Hashable, Sendable {
    public static let scheme = "yellowhammer"
    static let host = "project"

    public let project: ProjectID

    public init(project: ProjectID) {
        self.project = project
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host
        components.path = "/\(project.rawValue)"
        // A ProjectID is ASCII [A-Za-z0-9_-], so the components always form a valid URL.
        return components.url!
    }

    /// Reads a link, or returns nil for anything that is not exactly `yellowhammer://project/<id>`
    /// with a valid Project id. Scheme and host compare case-insensitively, as URLs do; the id does not.
    public init?(url: URL) {
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.scheme?.lowercased() == Self.scheme,
            components.host?.lowercased() == Self.host,
            components.user == nil, components.password == nil, components.port == nil,
            components.query == nil, components.fragment == nil
        else { return nil }
        var path = components.path
        if path.hasSuffix("/") { path.removeLast() }
        guard path.hasPrefix("/") else { return nil }
        guard let project = ProjectID(rawValue: String(path.dropFirst())) else { return nil }
        self.project = project
    }
}
