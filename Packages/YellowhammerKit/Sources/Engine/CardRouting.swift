import Domain
import Foundation
import Journal

/// Resolves a Card's Route at dispatch and writes the routing consequence to the Journal
/// (routing/resolve-a-route-for-a-card, roadmap P7.6): an Attempt carrying the resolved Route, or —
/// with zero candidates — the Blocked transition with Block Reason `route failure` and no Attempt, so
/// no phantom Attempt is spent. A refused Override writes nothing but its event: it is a Readiness
/// Check failure, which the Readiness Check (P8.2) reports onto the Card. The Repo Lane moving on to
/// its next Card is the Card loop's job (P8.4); this type writes only the routing consequence.
///
/// The resolved Route reaches the Card through the Attempt: the Card's Managed Block renders every
/// Attempt with its Route, so the morning can see which route produced the work.
///
/// Route exclusion on retry (routing/exclude-tried-routes-on-retry, roadmap P7.7): an Override pinned
/// in triage beats attempt-history exclusion, so an Operator pin that differs from the last Attempt's
/// pin in the Card's current budget epoch resets that epoch before resolution — the earlier epoch's
/// exclusions stop applying, and the Attempt records which pin produced it.
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
        /// The Card's current budget epoch has already consumed `attemptsPerWorkCard` Attempts: the Card as
        /// it stands, untouched — no Attempt is recorded and the resolver is never asked (roadmap P8.7).
        /// The caller Blocks the Card; this type writes nothing but what selection already wrote.
        case attemptBudgetSpent(CardRecord)
    }

    /// Resolves and records for one Card. `repoRole` is the role of the Card's Repo and `override`
    /// the Operator's pins read from the board; both are the caller's, because the Engine holds no
    /// configuration and reads the board only through the Delta Read. `checkDeclaredNone` is copied
    /// onto the Attempt exactly as
    /// ``JournalStore/recordAttempt(cardID:route:checkDeclaredNone:routeSource:override:runID:act:nightID:now:)``
    /// takes it, along with the resolved Route's ``ResolvedRoute/source`` and the Operator's Override.
    ///
    /// `attemptsPerWorkCard` is the Attempt budget guard (roadmap P8.7): when given and the Card's current
    /// budget epoch has already consumed that many Attempts — from this run's own retries or an earlier
    /// Act or Night, the counters live in the Journal and survive either — this returns
    /// ``Outcome/attemptBudgetSpent(_:)`` instead of resolving, so a Card that arrives already spent
    /// dispatches nothing. Checked after the Override-pin epoch reset and before resolution, so a pin
    /// that starts a fresh epoch also gets a fresh budget. `nil` (the default) never guards, for the
    /// existing callers that hold no Attempt budget.
    public func route(
        card: CardRecord,
        repoRole: RepoRole?,
        override: Override,
        checkDeclaredNone: Bool = false,
        attemptsPerWorkCard: Int? = nil
    ) async throws -> Outcome {
        guard let kind = Kind(card.kind) else {
            throw CardRoutingError.kindUnparseable(cardID: card.id, kind: card.kind)
        }

        let card = try resetEpochIfOverridePinChanged(card: card, override: override)

        if let attemptsPerWorkCard {
            let consumed = try journal.attemptHistory(cardID: card.id).consumption(inEpoch: card.budgetEpoch).consumed
            if consumed >= attemptsPerWorkCard {
                return .attemptBudgetSpent(card)
            }
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
                cardID: card.id, route: resolved.route, checkDeclaredNone: checkDeclaredNone,
                routeSource: resolved.source, override: override, runID: runID, act: act, nightID: nightID
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

    /// The triage-Override rule (routing/exclude-tried-routes-on-retry, P7.7): an Override beats
    /// attempt-history exclusion, so pinning one in triage that differs from the pin the Card's last
    /// Attempt in its current budget epoch ran under resets that epoch — the exclusions it recorded
    /// stop applying. Never resets when the epoch has no Attempt yet, and never when the last Attempt
    /// already ran under this same pin.
    private func resetEpochIfOverridePinChanged(card: CardRecord, override: Override) throws -> CardRecord {
        guard !override.isEmpty else { return card }
        let history = try journal.attemptHistory(cardID: card.id)
        let current = history.attempts.filter { $0.budgetEpoch == card.budgetEpoch }
        guard let last = current.last, last.overridePin != override.description else {
            return card
        }
        return try journal.resetBudgetEpoch(
            cardID: card.id, reason: "Override `\(override)` pinned in triage",
            runID: runID, act: act, nightID: nightID
        )
    }

    /// Blocked, through the projection when there is one, with the Block Reason the single derivation
    /// gives for the epoch's last ended Attempt (``AttemptHistory/blockReason(inEpoch:)``): `hard
    /// failure` when nothing was ever dispatched, and otherwise whatever that Attempt's own ending
    /// says (Attempt, Block and Reset Ruling 2026-09-19, OQ58).
    private func block(_ card: CardRecord) async throws -> CardRecord {
        let reason = try journal.attemptHistory(cardID: card.id).blockReason(inEpoch: card.budgetEpoch)
        guard let projection else {
            return try journal.transitionCard(
                cardID: card.id, to: .blocked, blockReason: reason, runID: runID, act: act, nightID: nightID
            )
        }
        switch try await projection.transition(card: card, to: .blocked(reason)) {
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
