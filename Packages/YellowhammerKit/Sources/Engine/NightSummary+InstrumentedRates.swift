import Domain
import Foundation
import Journal

/// Project-only counters rendered from recorded Nights. Fractions keep their numerator and
/// denominator visible; an empty denominator is reported as unmeasured, never as a zero rate.
extension NightSummary {
    public static func instrumentedRateLines(
        night: NightRecord, journal: JournalStore, bounds: NightCardMaintenance.Bounds
    ) throws -> [String] {
        let scope = try RateScope(night: night, journal: journal)
        return try instrumentedRateLines(scope: scope, night: night, journal: journal, bounds: bounds)
    }

    public static func instrumentedRateLines(
        scope: RateScope, night: NightRecord, journal: JournalStore, bounds: NightCardMaintenance.Bounds
    ) throws -> [String] {
        let nights = scope.nights
        let events = try journal.events()
        let relevant = events.filter { $0.nightID.map(scope.nightIDs.contains) ?? false }
        let accepted = acceptedCards(events: relevant)
        let greenCards = Set(relevant.compactMap { record -> String? in
            if case .cardStateTransitioned(_, let issueID, _, .done, _, _) = record.event { return issueID }
            return nil
        })
        let clean = cleanAcceptedCards(accepted, events: relevant)
        let completed = nights.filter { $0.state == .closed }
        let prNights = try completed.filter { candidate in
            var touched = Set(relevant.compactMap { record -> String? in
                guard record.nightID == candidate.id else { return nil }
                if case .repoLaneStarted(let repository, _) = record.event { return repository }
                return nil
            })
            let requests = try journal.pullRequests(nightID: candidate.id)
            let opened = Set(requests.map(\.repository))
            for request in requests {
                if let cycleID = try journal.cycleID(featureID: request.featureID) {
                    touched.formUnion(try journal.cards(cycleID: cycleID).map(\.repository))
                }
            }
            return !touched.isEmpty && touched.isSubset(of: opened)
        }
        let readyCounts = try journal.openingReadyCounts(through: night.nightStart, mode: scope.mode)
        let retries = relevant.compactMap { record -> Bool? in
            if case .routeRetried(_, _, _, _, let different) = record.event { return different }
            return nil
        }
        let differentRetries = retries.filter { $0 }.count
        let everyRetry = retries.isEmpty ? "unmeasured" : (differentRetries == retries.count ? "yes" : "no")
        let citationCount = try journal.closingAuthorSuppliedCitationCount(nightID: night.id)
            ?? journal.authorSuppliedCitationCount()
        return [
            "Green Cards accepted without a human comment or move out of Done since Done: " +
                ratio(clean.count, greenCards.count) + ". Upper bound: GitHub review activity is not observed.",
            "Closed Nights with a pull request in every touched repository: " +
                ratio(prNights.count, completed.count) + ".",
            "Nights started with zero Ready Cards: \(readyCounts.zero) of \(nights.count); " +
                "\(readyCounts.nonzero) nonzero, \(readyCounts.unknown) unknown.",
            "Retries on a different route: \(ratio(differentRetries, retries.count)); " +
                "every retry different: \(everyRetry).",
            "`author_supplied_citation_count`: \(citationCount) (at this Night's close)."
        ] + boundProximityLines(
            try boundProximity(scope: scope, night: night, events: relevant, journal: journal, bounds: bounds)
        )
    }

    private static func ratio(_ numerator: Int, _ denominator: Int) -> String {
        guard denominator > 0 else { return "unmeasured (0/0)" }
        return "\(numerator)/\(denominator) (\(numerator * 100 / denominator)%)"
    }

    private static func acceptedCards(events: [JournalEventRecord]) -> [String: Date] {
        events.reduce(into: [String: Date]()) { cards, record in
            switch record.event {
            case .featureSettled(_, _, let accepted, _),
                 .featureClosedByMerge(_, _, _, _, let accepted, _):
                for card in accepted where cards[card] == nil { cards[card] = record.occurredAt }
            default: break
            }
        }
    }

    private static func cleanAcceptedCards(
        _ accepted: [String: Date], events: [JournalEventRecord]
    ) -> Set<String> {
        var doneAt: [Int64: Date] = [:]
        var issueIDs: [Int64: String] = [:]
        var reopened: Set<Int64> = []
        for record in events {
            if case .cardStateTransitioned(let cardID, let issueID, _, let to, _, _) = record.event {
                issueIDs[cardID] = issueID
                if to == .done, doneAt[cardID] == nil {
                    doneAt[cardID] = record.occurredAt
                } else if doneAt[cardID] != nil && record.occurredAt <= (accepted[issueID] ?? .distantPast) {
                    reopened.insert(cardID)
                }
            }
            if case .cardRestated(let cardID, _, let journalState, let boardState) = record.event,
               journalState == .done, boardState != CardState.done.rawValue,
               let acceptedAt = accepted[issueIDs[cardID] ?? ""], record.occurredAt <= acceptedAt {
                reopened.insert(cardID)
            }
            if case .cardShelved(let cardID, let issueID, let previous) = record.event, previous == .done,
               record.occurredAt <= (accepted[issueID] ?? .distantPast) {
                reopened.insert(cardID)
            }
        }
        var commented: Set<Int64> = []
        for record in events {
            if case .humanCardComment(let cardID, _, let commentedAt) = record.event,
               let done = doneAt[cardID], let acceptedAt = accepted[issueIDs[cardID] ?? ""],
               commentedAt >= done, commentedAt <= acceptedAt {
                commented.insert(cardID)
            }
        }
        return Set(issueIDs.compactMap { cardID, issueID in
            accepted[issueID].map { acceptedAt in (doneAt[cardID] ?? .distantFuture) <= acceptedAt } == true
                && !reopened.contains(cardID)
                && !commented.contains(cardID) ? issueID : nil
        })
    }
}
