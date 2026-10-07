import Domain
import Foundation
import Journal

/// One Project Bound's proximity at a Night's close: what the Bound allows (`value`), what this Night
/// recorded against it (`observed`), and — when the Night Summary's line names what it counted — the
/// `measure` phrase. Always in the same six-Bound order: `review_rounds_max`, `attempts_per_work_card`,
/// `overdue_nights_max`, `reselections_max`, `consecutive_refusals_max`, `failed_adoptions_max`.
public struct BoundProximity: Sendable, Equatable {
    public let name: String
    public let value: Int
    public let observed: Int
    public let measure: String?

    public init(name: String, value: Int, observed: Int, measure: String?) {
        self.name = name
        self.value = value
        self.observed = observed
        self.measure = measure
    }
}

extension NightSummary {
    /// The Project Bounds' proximity at this Night's close, read fresh from the Journal: every Night up
    /// to and including this one, and only the events belonging to one of them — the same filtering
    /// `instrumentedRateLines` applies before computing proximity, reused here for a caller (Recalibrate)
    /// that never assembles a Night Summary itself.
    public static func boundProximity(
        night: NightRecord, journal: JournalStore, bounds: NightCardMaintenance.Bounds
    ) throws -> [BoundProximity] {
        let scope = try RateScope(night: night, journal: journal)
        return try boundProximity(scope: scope, night: night, journal: journal, bounds: bounds)
    }

    public static func boundProximity(
        scope: RateScope, night: NightRecord, journal: JournalStore, bounds: NightCardMaintenance.Bounds
    ) throws -> [BoundProximity] {
        let events = try journal.events().filter { $0.nightID.map(scope.nightIDs.contains) ?? false }
        return try boundProximity(scope: scope, night: night, events: events, journal: journal, bounds: bounds)
    }

    /// The Project Bounds' proximity at this Night's close. Card counters come from the immutable
    /// closure snapshot, while Attempt histories are cut at close.
    static func boundProximity(
        scope: RateScope, night: NightRecord, events: [JournalEventRecord], journal: JournalStore,
        bounds: NightCardMaintenance.Bounds
    ) throws -> [BoundProximity] {
        try boundProximity(night: night, events: events, journal: journal, bounds: bounds)
    }

    static func boundProximity(
        night: NightRecord, events: [JournalEventRecord], journal: JournalStore,
        bounds: NightCardMaintenance.Bounds
    ) throws -> [BoundProximity] {
        let current = events.filter { $0.nightID == night.id }
        let close = night.completedAt ?? Date.distantFuture
        let (rounds, attempts) = try attemptCounters(current: current, journal: journal, close: close)
        let cardCounts = try cardCounters(night: night, current: current, journal: journal)
        let reselections = cardCounts.reselections
        let refusals = cardCounts.refusals
        let unanswered = cardCounts.unanswered
        let failedAdoptions = cardCounts.failedAdoptions
        return [
            BoundProximity(
                name: "review_rounds_max", value: bounds.reviewRoundsMax, observed: rounds,
                measure: "highest Rounds in an Attempt"
            ),
            BoundProximity(
                name: "attempts_per_work_card", value: bounds.attemptsPerWorkCard, observed: attempts,
                measure: "highest consumed in an epoch"
            ),
            BoundProximity(
                name: "overdue_nights_max", value: bounds.unansweredNightsMax, observed: unanswered,
                measure: "highest Card count"
            ),
            BoundProximity(
                name: "reselections_max", value: bounds.reselectionsMax, observed: reselections, measure: nil
            ),
            BoundProximity(
                name: "consecutive_refusals_max", value: bounds.consecutiveRefusalsMax, observed: refusals, measure: nil
            ),
            BoundProximity(
                name: "failed_adoptions_max", value: bounds.failedAdoptionsMax, observed: failedAdoptions, measure: nil
            )
        ]
    }

    /// `review_rounds_max`/`attempts_per_work_card`'s counters: the highest Rounds an Attempt reached, and the
    /// highest Attempts consumed in one budget epoch, across every Card this Night touched.
    private static func attemptCounters(
        current: [JournalEventRecord], journal: JournalStore, close: Date
    ) throws -> (rounds: Int, attempts: Int) {
        let cards = try touchedCards(events: current, journal: journal)
        var rounds = 0
        var attempts = 0
        for card in cards {
            let history = try journal.attemptHistory(cardID: card.id)
            let byEpoch = Dictionary(grouping: history.attempts.filter { $0.startedAt <= close }, by: \.budgetEpoch)
            for epochAttempts in byEpoch.values {
                let consumed = epochAttempts.filter {
                    let resultAtClose = ($0.endedAt ?? .distantFuture) <= close ? $0.result : nil
                    return resultAtClose != AttemptOutcome.question.rawValue &&
                        resultAtClose != AttemptOutcome.cancelled.rawValue &&
                        resultAtClose != AttemptOutcome.aborted.rawValue
                }.count
                attempts = max(attempts, consumed)
            }
            for attempt in history.attempts where attempt.startedAt <= close {
                rounds = max(rounds, attempt.rounds.filter { $0.createdAt <= close }.count)
            }
        }
        return (rounds, attempts)
    }

    /// `reselections_max`/`consecutive_refusals_max`/`overdue_nights_max`/`failed_adoptions_max`'s
    /// counters, grouped to keep ``cardCounters(night:current:journal:)`` under SwiftLint's tuple-member
    /// limit.
    private struct CardCounts {
        let reselections: Int
        let refusals: Int
        let unanswered: Int
        let failedAdoptions: Int
    }

    /// The latter two of ``CardCounts`` start from the closing snapshot, and every counter is the
    /// highest this Night's own events recorded.
    private static func cardCounters(
        night: NightRecord, current: [JournalEventRecord], journal: JournalStore
    ) throws -> CardCounts {
        let closedCounters = try journal.closingCardBoundCounters(nightID: night.id)
        var reselections = 0
        var refusals = 0
        var unanswered = closedCounters?.unanswered ?? 0
        var failedAdoptions = closedCounters?.failedAdoptions ?? 0
        for record in current {
            switch record.event {
            case .featureReselected(let depth, _, _): reselections = max(reselections, depth)
            case .refusalOpened(_, let count, _, _), .refusalRepeated(_, let count, _, _):
                refusals = max(refusals, count)
            case .cardUnansweredBoundFired(_, _, let count, _, _): unanswered = max(unanswered, count)
            case .cardPromotedToStandingItem(_, _, let count, _): failedAdoptions = max(failedAdoptions, count)
            default: break
            }
        }
        return CardCounts(
            reselections: reselections, refusals: refusals, unanswered: unanswered, failedAdoptions: failedAdoptions
        )
    }

    /// Renders ``BoundProximity`` values into the Night Summary's own lines, byte-identical to what this
    /// file produced before the struct existed.
    static func boundProximityLines(_ proximities: [BoundProximity]) -> [String] {
        proximities.map { proximity in
            let suffix = proximity.measure.map { " (\($0))" } ?? ""
            return "`\(proximity.name)`: \(proximity.observed) of \(proximity.value)\(suffix)."
        }
    }
}
