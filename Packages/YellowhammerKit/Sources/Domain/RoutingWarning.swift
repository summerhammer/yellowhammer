/// A proactive warning about the Routing Table's resilience (routing/overview, OQ13): "Setup and
/// `yh doctor` issue proactive warnings for any routing entry lacking fallbacks or relying on a single
/// CLI". With 0 candidate routes left, a Card is Blocked `route failure` immediately.
public enum RoutingWarning: Hashable, Sendable {
    /// The Routing Table has no entries at all: nothing can be dispatched.
    case noEntries
    /// The entry's `fallbacks` is empty.
    case noFallbacks(RoutingEntry.Key)
    /// The entry has fallbacks, but its primary route and every fallback name the same CLI.
    case singleCLI(RoutingEntry.Key, cli: String)
    /// Every Route the authoring Work Kind can resolve to is also a Route a Work Card can resolve to
    /// (OQ154), so Verification can fault (`VerificationDispatchFault`). When `everyCycle` is true,
    /// that is a single Route every Work Card takes first, so Verification faults on every Cycle.
    case verificationRouteReachability(everyCycle: Bool)
}

extension RoutingWarning: CustomStringConvertible {
    public var description: String {
        switch self {
        case .noEntries:
            return "the Routing Table has no entries: no Card can be dispatched"
        case .noFallbacks(let key):
            return "routing entry kind \"\(key.kind)\" repo_role \"\(Self.repoRoleDescription(key.repoRole))\" has no "
                + "fallbacks: a Card whose route fails is Blocked with route failure at once"
        case .singleCLI(let key, let cli):
            return "routing entry kind \"\(key.kind)\" repo_role \"\(Self.repoRoleDescription(key.repoRole))\" "
                + "relies on a single CLI (\"\(cli)\"): if that CLI fails, no route remains and the Card is "
                + "Blocked with route failure at once"
        case .verificationRouteReachability(let everyCycle):
            let faultCondition = everyCycle
                ? "once a Cycle's worker Attempts have used each of those Routes, and faults on every Cycle "
                    + "when that is a single Route every Work Card takes first"
                : "once a Cycle's worker Attempts have used each of those Routes"
            return "every Route the authoring Work Kind can resolve to is also a Route a Work Card can resolve to "
                + "in the Routing Table: Verification can fault (VerificationDispatchFault) \(faultCondition); "
                + "remedy: add a fallback, or an authoring entry, whose Route no Work Card can resolve to"
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
        var result: [RoutingWarning] = compactMap { entry in
            guard !entry.fallbacks.isEmpty else {
                return .noFallbacks(entry.key)
            }
            let clis = Set(([entry.route] + entry.fallbacks).map(\.cli))
            guard clis.count == 1 else { return nil }
            return .singleCLI(entry.key, cli: entry.route.cli)
        }
        if let reachability = verificationReachabilityWarning {
            result.append(reachability)
        }
        return result
    }

    private var authoringEntry: RoutingEntry? {
        var best: RoutingEntry?
        for entry in self where entry.repoRole == .any && entry.kind.isPrefix(of: .authoring) {
            guard let current = best else {
                best = entry
                continue
            }
            if entry.kind.specificity > current.kind.specificity {
                best = entry
            }
        }
        return best
    }

    private var workCardEntries: [RoutingEntry] {
        filter { !$0.kind.isReservedForAuthoring }
    }

    private var verificationReachabilityWarning: RoutingWarning? {
        guard let authoringEntry else { return nil }
        let authoringCandidates = [authoringEntry.route] + authoringEntry.fallbacks
        let authoringRoutes = Set(authoringCandidates)
        guard !authoringRoutes.isEmpty else { return nil }

        let workCards = workCardEntries
        guard !workCards.isEmpty else { return nil }
        let workCardRoutes = Set(workCards.flatMap { [$0.route] + $0.fallbacks })

        guard authoringRoutes.isSubset(of: workCardRoutes) else { return nil }

        let singleRoute = authoringCandidates[0]
        let everyCycle = authoringRoutes.count == 1 && workCards.allSatisfy { $0.route == singleRoute }
        return .verificationRouteReachability(everyCycle: everyCycle)
    }
}

extension RoutingTable {
    /// The proactive warnings for this Routing Table, in entry order.
    public var warnings: [RoutingWarning] {
        entries.warnings
    }
}
