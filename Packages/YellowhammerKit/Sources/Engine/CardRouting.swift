import Domain
import Foundation
import Journal

/// Resolves a Card's Route at dispatch and writes the routing consequence to the Journal
/// (routing/resolve-a-route-for-a-card, roadmap P7.6): an Attempt carrying the resolved Route, or —
/// with zero candidates — the Blocked transition with Block Reason `hard failure` and no Attempt, so
/// no phantom Attempt is spent. A refused Override writes nothing but its event: it is a Readiness
/// Check failure, which the Readiness Check (P8.2) reports onto the Card. The Repo Lane moving on to
/// its next Card is the Card loop's job (P8.4); this type writes only the routing consequence.
///
/// The resolved Route reaches the Card through the Attempt: the Card's Managed Block renders every
/// Attempt with its Route, so the morning can see which route produced the work.
public struct CardRouting: Sendable {
    public let resolver: RouteResolver
    public let journal: JournalStore
    /// The board projection for the Blocked transition; nil when the invocation has no Board, in
    /// which case the transition is written to the Journal alone and reposted on a later Act.
    public let projection: BoardStateProjection?
    public let runID: RunID
    public let act: Act
    public let nightID: Int64?

    public init(
        resolver: RouteResolver,
        journal: JournalStore,
        projection: BoardStateProjection? = nil,
        runID: RunID,
        act: Act,
        nightID: Int64? = nil
    ) {
        self.resolver = resolver
        self.journal = journal
        self.projection = projection
        self.runID = runID
        self.act = act
        self.nightID = nightID
    }

    public enum Outcome: Equatable, Sendable {
        /// The Attempt recorded on the resolved Route.
        case attempt(AttemptRecord, ResolvedRoute)
        /// Zero candidates: the Card as it stands after the Blocked transition, and no Attempt.
        case blocked(CardRecord, RouteExhaustion)
        /// The Override was refused: the Card untouched, no Attempt, the refusal to report.
        case readinessFailure(CardRecord, OverrideRefusal)
    }

    /// Resolves and records for one Card. `repoRole` is the role of the Card's Repo and `override`
    /// the Operator's pins read from the board; both are the caller's, because the Engine holds no
    /// configuration and reads the board only through the Delta Read. `checkDeclaredNone` is copied
    /// onto the Attempt exactly as ``JournalStore/recordAttempt(cardID:route:checkDeclaredNone:runID:now:)``
    /// takes it.
    public func route(
        card: CardRecord,
        repoRole: RepoRole?,
        override: Override,
        checkDeclaredNone: Bool = false
    ) async throws -> Outcome {
        guard let kind = Kind(card.kind) else {
            throw CardRoutingError.kindUnparseable(cardID: card.id, kind: card.kind)
        }
        let request = RouteRequest(
            kind: kind,
            repoRole: repoRole,
            override: override,
            excludedRoutes: try journal.excludedRoutes(cardID: card.id)
        )
        switch try resolver.resolve(request) {
        case .resolved(let resolved):
            let attempt = try journal.recordAttempt(
                cardID: card.id, route: resolved.route, checkDeclaredNone: checkDeclaredNone, runID: runID
            )
            return .attempt(attempt, resolved)
        case .exhausted(let exhaustion):
            _ = try journal.append(
                .routeExhausted(cardID: card.id, issueID: card.issueID, reason: exhaustion.description),
                act: act, runID: runID, nightID: nightID
            )
            return .blocked(try await block(card), exhaustion)
        case .overrideRefused(let refusal):
            _ = try journal.append(
                .overrideRefused(cardID: card.id, issueID: card.issueID, reason: refusal.description),
                act: act, runID: runID, nightID: nightID
            )
            return .readinessFailure(card, refusal)
        }
    }

    /// Blocked with Block Reason `hard failure`, through the projection when there is one.
    private func block(_ card: CardRecord) async throws -> CardRecord {
        guard let projection else {
            return try journal.transitionCard(
                cardID: card.id, to: .blocked, blockReason: .hardFailure, runID: runID, act: act, nightID: nightID
            )
        }
        switch try await projection.transition(card: card, to: .blocked(.hardFailure)) {
        case .unchanged(let record), .posted(let record, _), .deferred(let record, _), .failed(let record, _):
            return record
        }
    }
}

public enum CardRoutingError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The Journal holds a Card whose `kind` is not a Kind; nothing this engine wrote.
    case kindUnparseable(cardID: Int64, kind: String)

    public var description: String {
        switch self {
        case .kindUnparseable(let cardID, let kind):
            "Card \(cardID) has a kind that is not a Kind: '\(kind)'"
        }
    }
}
