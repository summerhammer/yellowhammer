import Domain
import Foundation

/// What resolving a Route for a Card came to (routing/resolve-a-route-for-a-card).
public enum RouteResolution: Equatable, Sendable {
    /// A Route was selected and survived the filters: the Attempt is recorded on it.
    case resolved(ResolvedRoute)
    /// Zero candidates remain — fallbacks exhausted. The Card moves to Blocked with Block Reason
    /// `hard failure`, no Attempt is recorded, and its Repo Lane moves on (OQ13).
    case exhausted(RouteExhaustion)
    /// The Operator's Override cannot resolve, or pins a Route whose CLI failed its Probe: a Readiness
    /// Check failure, never a silent fallthrough (G-17). No Attempt, and the Card's state is untouched.
    case overrideRefused(OverrideRefusal)
}

/// The Route a Card was resolved to, and how.
public struct ResolvedRoute: Equatable, Sendable {
    public enum Selection: Equatable, Sendable {
        /// The Operator's Override named it, whole (OQ126).
        case override
        /// The Routing Entry's route or one of its fallbacks, after the filters.
        case entry
    }

    public var route: Route
    /// The Routing Entry the selection stage matched; nil only under an Override with no matching
    /// entry. Under an Override it is a record only: no part of the Route comes from it.
    public var entry: RoutingEntry.Key?
    public var selectedBy: Selection
    /// The entry's candidates the filters dropped before this one, in the order they were tried.
    public var skipped: [SkippedCandidate]

    public init(route: Route, entry: RoutingEntry.Key?, selectedBy: Selection, skipped: [SkippedCandidate]) {
        self.route = route
        self.entry = entry
        self.selectedBy = selectedBy
        self.skipped = skipped
    }

    /// How this Route was selected, for the Attempt's `route_source` (object guide: `route_source`
    /// enum `{entry, fallback, override}` plus fallback position; routing/exclude-tried-routes-on-retry,
    /// P7.7): `override` under the Operator's pin; otherwise `entry` when the Routing Entry's primary
    /// route survived the filters (position 0, so `skipped` is empty), else `fallback:<n>` where `n` is
    /// the 1-based position among the entry's fallbacks — equal to `skipped.count`, since every
    /// candidate ahead of this one was filtered out.
    public var source: String {
        switch selectedBy {
        case .override:
            "override"
        case .entry:
            skipped.isEmpty ? "entry" : "fallback:\(skipped.count)"
        }
    }
}

/// One of a Routing Entry's candidates a filter dropped, and which filter.
public struct SkippedCandidate: Equatable, Sendable, CustomStringConvertible {
    public enum Reason: Equatable, Sendable {
        /// Attempt history excludes the Route for this Card in its current budget epoch.
        case attemptHistory
        /// The Route's CLI is not offered as a route target: its latest Probe failed, or it was never
        /// probed. The reason is the Ledger's, Operator-facing.
        case probe(String)
    }

    public var route: Route
    public var reason: Reason

    public init(route: Route, reason: Reason) {
        self.route = route
        self.reason = reason
    }

    public var description: String {
        switch reason {
        case .attemptHistory:
            "`\(route)` excluded by attempt history"
        case .probe(let reason):
            "`\(route)` not offered by its Probe (\(reason))"
        }
    }
}

/// Zero candidates remained for a Card: no Routing Entry matched, or every candidate of the matched
/// entry was filtered out. ``description`` is the Operator-facing account recorded in the Journal.
public struct RouteExhaustion: Equatable, Sendable, CustomStringConvertible {
    public var kind: Kind
    public var repoRole: RepoRole?
    /// The Routing Entry whose candidates ran out; nil when no entry matched at all.
    public var entry: RoutingEntry.Key?
    /// Every candidate tried, in order, with the filter that dropped it. Empty when no entry matched.
    public var skipped: [SkippedCandidate]

    public init(kind: Kind, repoRole: RepoRole?, entry: RoutingEntry.Key?, skipped: [SkippedCandidate]) {
        self.kind = kind
        self.repoRole = repoRole
        self.entry = entry
        self.skipped = skipped
    }

    public var description: String {
        let card = "Kind `\(kind)`, Repo Role \(repoRole.map { "`\($0.rawValue)`" } ?? "unknown")"
        guard let entry else {
            return "fallbacks exhausted: no Routing Entry matches the Card (\(card))"
        }
        let dropped = skipped.map(\.description).joined(separator: "; ")
        return "fallbacks exhausted for the Routing Entry \(entry.account) (\(card)): \(dropped)"
    }
}

/// Why an Override was refused: a Readiness Check failure, reported and never dispatched (G-17, OQ126).
public enum OverrideRefusal: Equatable, Sendable, CustomStringConvertible {
    /// The label is neither a Route of the Project's Routing Table nor a three-part `cli/model/effort`.
    case unresolvable(Override, reason: String)
    /// The Route's CLI is not offered as a route target: its Probe failed, or it was never probed.
    case probeFailed(Override, cli: String, reason: String)
    /// The Route's CLI refused it, or could not run it, in its Route Pre-flight (OQ126).
    case preflightFailed(Override, route: Route, reason: String)

    public var description: String {
        switch self {
        case .unresolvable(let override, let reason):
            "Override `\(override)` cannot resolve: \(reason)"
        case .probeFailed(let override, let cli, let reason):
            "Override `\(override)` pins `\(cli)`, which is not offered by its Probe: \(reason)"
        case .preflightFailed(let override, let route, let reason):
            "Override `\(override)` failed its Route Pre-flight on `\(route)`: \(reason)"
        }
    }
}

extension RoutingEntry.Key {
    /// `kind `impl`, Repo Role `backend`` — how a Routing Entry is named in an account.
    var account: String {
        switch repoRole {
        case .any:
            "(kind `\(kind)`, any Repo Role)"
        case .role(let role):
            "(kind `\(kind)`, Repo Role `\(role.rawValue)`)"
        }
    }
}
