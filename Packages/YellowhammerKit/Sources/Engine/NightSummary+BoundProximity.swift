import Domain
import Foundation
import Journal

extension NightSummary {
    /// The Project Bounds' proximity at this Night's close. Card counters come from the immutable
    /// closure snapshot, while Attempt histories are cut at close.
    static func boundProximity(
        night: NightRecord, events: [JournalEventRecord], journal: JournalStore,
        bounds: NightCardMaintenance.Bounds
    ) throws -> [String] {
        let current = events.filter { $0.nightID == night.id }
        let cards = try touchedCards(events: current, journal: journal)
        let close = night.completedAt ?? Date.distantFuture
        var rounds = 0
        var attempts = 0
        let closedCounters = try journal.closingCardBoundCounters(nightID: night.id)
        var unanswered = closedCounters?.unanswered ?? 0
        var failedAdoptions = closedCounters?.failedAdoptions ?? 0
        for card in cards {
            let history = try journal.attemptHistory(cardID: card.id)
            let byEpoch = Dictionary(grouping: history.attempts.filter { $0.startedAt <= close }, by: \.budgetEpoch)
            for epochAttempts in byEpoch.values {
                let consumed = epochAttempts.filter {
                    let resultAtClose = ($0.endedAt ?? .distantFuture) <= close ? $0.result : nil
                    return resultAtClose != AttemptOutcome.question.rawValue &&
                        resultAtClose != AttemptOutcome.cancelled.rawValue
                }.count
                attempts = max(attempts, consumed)
            }
            for attempt in history.attempts where attempt.startedAt <= close {
                rounds = max(rounds, attempt.rounds.filter { $0.createdAt <= close }.count)
            }
        }
        var reselections = 0
        var refusals = 0
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
        return [
            "`review_rounds_max`: \(rounds) of \(bounds.reviewRoundsMax) (highest Rounds in an Attempt).",
            "`attempts_per_card`: \(attempts) of \(bounds.attemptsPerCard) (highest consumed in an epoch).",
            "`unanswered_nights_max`: \(unanswered) of \(bounds.unansweredNightsMax) (highest Card count).",
            "`reselections_max`: \(reselections) of \(bounds.reselectionsMax).",
            "`consecutive_refusals_max`: \(refusals) of \(bounds.consecutiveRefusalsMax).",
            "`failed_adoptions_max`: \(failedAdoptions) of \(bounds.failedAdoptionsMax)."
        ]
    }
}
