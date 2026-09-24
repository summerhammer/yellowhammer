/// A proactive warning about the Routing Table's resilience (routing/overview, OQ13): "Setup and
/// `yh doctor` issue proactive warnings for any routing entry lacking fallbacks or relying on a single
/// CLI". With 0 candidate routes left, a Card is Blocked `hard failure` immediately.
public enum RoutingWarning: Hashable, Sendable {
    /// The Routing Table has no entries at all: nothing can be dispatched.
    case noEntries
    /// The entry's `fallbacks` is empty.
    case noFallbacks(RoutingEntry.Key)
    /// The entry has fallbacks, but its primary route and every fallback name the same CLI.
    case singleCLI(RoutingEntry.Key, cli: String)
}

extension RoutingWarning: CustomStringConvertible {
    public var description: String {
        switch self {
        case .noEntries:
            "the Routing Table has no entries: no Card can be dispatched"
        case .noFallbacks(let key):
            "routing entry kind \"\(key.kind)\" repo_role \"\(Self.repoRoleDescription(key.repoRole))\" has no "
                + "fallbacks: a Card whose route fails is Blocked with hard failure at once"
        case .singleCLI(let key, let cli):
            "routing entry kind \"\(key.kind)\" repo_role \"\(Self.repoRoleDescription(key.repoRole))\" relies on "
                + "a single CLI (\"\(cli)\"): if that CLI fails, no route remains and the Card is Blocked with "
                + "hard failure at once"
        }
    }

    private static func repoRoleDescription(_ match: RepoRoleMatch) -> String {
        switch match {
        case .any: "*"
        case .role(let role): role.rawValue
        }
    }
}

extension [RoutingEntry] {
    /// The proactive warnings for this Routing Table's entries, in entry order.
    public var warnings: [RoutingWarning] {
        guard !isEmpty else { return [.noEntries] }
        return compactMap { entry in
            guard !entry.fallbacks.isEmpty else {
                return .noFallbacks(entry.key)
            }
            let clis = Set(([entry.route] + entry.fallbacks).map(\.cli))
            guard clis.count == 1 else { return nil }
            return .singleCLI(entry.key, cli: entry.route.cli)
        }
    }
}

extension RoutingTable {
    /// The proactive warnings for this Routing Table, in entry order.
    public var warnings: [RoutingWarning] {
        entries.warnings
    }
}
