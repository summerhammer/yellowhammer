/// How a Routing Entry names the Repo Role it applies to: a specific role, or any.
public enum RepoRoleMatch: Hashable, Sendable {
    case any
    case role(RepoRole)
}

/// One row of the Routing Table.
public struct RoutingEntry: Equatable, Sendable {
    public var kind: Kind
    public var repoRole: RepoRoleMatch
    public var route: Route
    /// In the order they are tried.
    public var fallbacks: [Route]

    public init(kind: Kind = .any, repoRole: RepoRoleMatch = .any, route: Route, fallbacks: [Route] = []) {
        self.kind = kind
        self.repoRole = repoRole
        self.route = route
        self.fallbacks = fallbacks
    }
}

extension RoutingEntry {
    /// What identifies a row: the merge and the duplicate check both key on it.
    public struct Key: Hashable, Sendable {
        public var kind: Kind
        public var repoRole: RepoRoleMatch

        public init(kind: Kind, repoRole: RepoRoleMatch) {
            self.kind = kind
            self.repoRole = repoRole
        }
    }

    public var key: Key {
        Key(kind: kind, repoRole: repoRole)
    }
}
