import Domain
import Foundation

/// What one Card brings to route resolution at dispatch (routing/resolve-a-route-for-a-card): its
/// Kind, its Repo's Repo Role, the Operator's Override read from the board, and the Routes attempt
/// history excludes in its current budget epoch.
public struct RouteRequest: Equatable, Sendable {
    public var kind: Kind
    /// The role of the Card's Repo; nil when the repository is not configured, in which case only
    /// Routing Entries for any Repo Role apply.
    public var repoRole: RepoRole?
    /// The Operator's Override, nil when the Card carries none.
    public var override: Override?
    /// The attempt-history exclusion set: every Route already excluded for this Card in its current
    /// budget epoch, held in the Journal (routing/exclude-tried-routes-on-retry).
    public var excludedRoutes: Set<Route>

    public init(kind: Kind, repoRole: RepoRole?, override: Override? = nil, excludedRoutes: Set<Route> = []) {
        self.kind = kind
        self.repoRole = repoRole
        self.override = override
        self.excludedRoutes = excludedRoutes
    }
}

/// Resolves a Route per Card at dispatch time over one Project's merged Routing Table
/// (routing/resolve-a-route-for-a-card, roadmap P7.6).
///
/// Resolution is two stages, not five ranked alternatives. It **selects** a Routing Entry — by
/// Override, then Kind by longest dotted-prefix match, then Repo Role — and then **filters** the
/// entry's candidates (its route, then its fallbacks in order) by attempt history and Probe failure.
/// An Override names a whole Route; it beats Kind, Repo Role and attempt-history exclusion but never Probe
/// failure, and under it the entry's fallbacks are not consulted (Decision Gates Ruling, G-17, as amended
/// by the Override Ruling, OQ126).
///
/// The table is the one the Act was handed: `EngineCommand` loads configuration on every Act, so the
/// table is read fresh each time. Nothing about resolution is learned, inferred or adapted from past
/// outcomes — the Probe verdict is read through ``probeEligibility`` and the exclusion set arrives
/// in the request; the resolver keeps nothing.
public struct RouteResolver: Sendable {
    /// Whether a CLI is offered as a route target, per its latest Probe Result in the Ledger. The
    /// Engine never opens the Ledger; `EngineCommand` binds this to it.
    public typealias ProbeEligibility = @Sendable (_ cli: String) throws -> RouteTargetEligibility

    public let table: RoutingTable
    public let probeEligibility: ProbeEligibility

    public init(table: RoutingTable, probeEligibility: @escaping ProbeEligibility) {
        self.table = table
        self.probeEligibility = probeEligibility
    }

    /// The selection stage alone: the Routing Entry whose Kind is the longest prefix of `kind` among
    /// those applying to `repoRole`; at equal Kind length, the entry naming the Repo Role beats the
    /// entry for any. Table order never decides. Nil when no entry matches.
    public func selectEntry(kind: Kind, repoRole: RepoRole?) -> RoutingEntry? {
        var best: RoutingEntry?
        for entry in table.entries
        where entry.kind.isPrefix(of: kind) && Self.applies(entry.repoRole, to: repoRole) {
            guard let current = best else {
                best = entry
                continue
            }
            if Self.rank(entry) > Self.rank(current) {
                best = entry
            }
        }
        return best
    }

    /// Resolves a Route for one Card. Throws only what ``probeEligibility`` throws.
    public func resolve(_ request: RouteRequest) throws -> RouteResolution {
        let entry = selectEntry(kind: request.kind, repoRole: request.repoRole)
        // The Ledger is asked at most once per distinct CLI in one resolution.
        var verdicts: [String: RouteTargetEligibility] = [:]
        func eligibility(_ cli: String) throws -> RouteTargetEligibility {
            if let known = verdicts[cli] {
                return known
            }
            let verdict = try probeEligibility(cli)
            verdicts[cli] = verdict
            return verdict
        }

        if let override = request.override {
            return try resolveOverride(override, entry: entry, eligibility: eligibility)
        }

        guard let entry else {
            return .exhausted(RouteExhaustion(kind: request.kind, repoRole: request.repoRole, entry: nil, skipped: []))
        }
        var skipped: [SkippedCandidate] = []
        for candidate in [entry.route] + entry.fallbacks {
            if request.excludedRoutes.contains(candidate) {
                skipped.append(SkippedCandidate(route: candidate, reason: .attemptHistory))
                continue
            }
            if case .excluded(let reason) = try eligibility(candidate.cli) {
                skipped.append(SkippedCandidate(route: candidate, reason: .probe(reason)))
                continue
            }
            return .resolved(ResolvedRoute(route: candidate, entry: entry.key, selectedBy: .entry, skipped: skipped))
        }
        return .exhausted(
            RouteExhaustion(kind: request.kind, repoRole: request.repoRole, entry: entry.key, skipped: skipped)
        )
    }

    // MARK: - Override

    /// Under an Override the label names the whole Route (OQ126): matched whole, case-insensitively,
    /// against the rendered Routes of the table — so a table Route whose model id contains `/` still
    /// resolves, spelled as the table spells it — and only then split as the three-part shorthand. No
    /// axis is ever taken from the entry. The Route is then checked against Probe failure only:
    /// attempt-history exclusion does not apply, because a lever the machine can silently veto is not a
    /// lever (G-17). Its Route Pre-flight is the caller's, because it runs the CLI.
    private func resolveOverride(
        _ override: Override,
        entry: RoutingEntry?,
        eligibility: (String) throws -> RouteTargetEligibility
    ) throws -> RouteResolution {
        let label = override.label.lowercased()
        guard let route = table.allRoutes.first(where: { $0.description.lowercased() == label })
            ?? Route(label: override.label)
        else {
            let reason = "it is neither a Route of the Project's Routing Table nor a three-part `cli/model/effort`"
            return .overrideRefused(.unresolvable(override, reason: reason))
        }
        if case .excluded(let reason) = try eligibility(route.cli) {
            return .overrideRefused(.probeFailed(override, cli: route.cli, reason: reason))
        }
        return .resolved(ResolvedRoute(route: route, entry: entry?.key, selectedBy: .override, skipped: []))
    }

    // MARK: - Selection

    private static func applies(_ match: RepoRoleMatch, to repoRole: RepoRole?) -> Bool {
        switch match {
        case .any:
            true
        case .role(let role):
            role == repoRole
        }
    }

    /// Kind specificity first, then whether the entry names the Repo Role.
    private static func rank(_ entry: RoutingEntry) -> (Int, Int) {
        (entry.kind.specificity, entry.repoRole == .any ? 0 : 1)
    }
}
