import Domain
import Foundation
import Journal

// The Night Summary's `**Standing: un-adopted Cards:**` section (roadmap P12.1): every Card left
// Blocked by a closed Feature, rendered on every completed Night Card while any exist — not only the
// Night it was left behind. No threshold, no truncation. Reported only, never acted on.

extension NightSummary {
    /// One line per un-adopted Card, in `journal.unadoptedCards(asOf:)`'s order: issue id, the closed
    /// Feature's issue id, its Block Reason, and elapsed Nights un-adopted. Empty when none exist.
    public static func unadoptedCardLines(night: NightRecord, journal: JournalStore) throws -> [String] {
        try journal.unadoptedCards(asOf: night.nightStart).map { unadopted in
            let card = unadopted.card
            let blockReason = card.blockReason ?? "no Block Reason recorded"
            let nightWord = unadopted.elapsedNights == 1 ? "Night" : "Nights"
            return "`\(card.issueID)` — \(blockReason), left by Feature `\(unadopted.closedFeatureIssueID)`; " +
                "un-adopted for \(unadopted.elapsedNights) \(nightWord)."
        }
    }

    /// The `**Standing: unmerged in-flight Feature:**` line (roadmap P12.1): rendered only while
    /// `journal.inFlightLandedFeature()` is non-nil — a landed but not-yet-merged Feature still holds
    /// the in-flight slot. Folds the old, per-Night `**Mainline Conflicts:**` section into this one
    /// standing line. Reported only, never acted on; renders the same shape while `k < N`, so 0 and
    /// any partial count read alike — the Feature still holds the slot either way.
    public static func inFlightFeatureLines(night: NightRecord, journal: JournalStore) throws -> [String] {
        guard let inFlight = try journal.inFlightLandedFeature() else { return [] }
        let featureIssueID = inFlight.feature.issueID
        let observation = try latestAncestryObservation(featureIssueID: featureIssueID, journal: journal)

        var line = "`\(featureIssueID)` — " +
            (try nightsHeldPhrase(featureID: inFlight.feature.id, night: night, journal: journal)) + "; " +
            mergePhrase(observation: observation, touchedRepositories: inFlight.touchedRepositories)
        if let conflicts = try conflictsPhrase(
            featureIssueID: featureIssueID, unmergedRepositories: observation?.unmerged, journal: journal
        ) {
            line += "; \(conflicts)"
        }
        return [line]
    }

    private static func nightsHeldPhrase(featureID: Int64, night: NightRecord, journal: JournalStore) throws -> String {
        guard let selectedNightID = try journal.selectedNightID(featureID: featureID),
            let held = try journal.nightsHeld(selectedNightID: selectedNightID, asOf: night.nightStart)
        else {
            return "the Night it entered flight is not recorded"
        }
        return "in flight for \(held) Night\(held == 1 ? "" : "s")"
    }

    private static func mergePhrase(
        observation: (merged: [String], unmerged: [String])?, touchedRepositories: [String]
    ) -> String {
        guard let observation else { return "the merge state has not been read yet" }
        return "\(observation.merged.count) of \(touchedRepositories.count) Feature Branches merged"
    }

    /// The latest `predecessorAncestryObserved` pass for this Feature, nil when none has run yet.
    private static func latestAncestryObservation(
        featureIssueID: String, journal: JournalStore
    ) throws -> (merged: [String], unmerged: [String])? {
        let events = try journal.events(ofType: .predecessorAncestryObserved)
        guard let latest = events.last(where: { record in
            guard case .predecessorAncestryObserved(let observed, _, _) = record.event else { return false }
            return observed == featureIssueID
        }), case .predecessorAncestryObserved(_, let merged, let unmerged) = latest.event else {
            return nil
        }
        return (merged, unmerged)
    }

    /// Which of the still-unmerged Feature Branches carry a Mainline Conflict, from the most recent
    /// Night that recorded any `mainlineConflictDetected` event for this Feature — not just this
    /// render's Night, since the line is a standing one. Nil when there is nothing unmerged yet to
    /// know about, or nothing to report.
    private static func conflictsPhrase(
        featureIssueID: String, unmergedRepositories: [String]?, journal: JournalStore
    ) throws -> String? {
        guard let unmergedRepositories, !unmergedRepositories.isEmpty else { return nil }
        let unmerged = Set(unmergedRepositories)
        let matching = try journal.events(ofType: .mainlineConflictDetected).filter { record in
            guard case .mainlineConflictDetected(let observed, _, _) = record.event else { return false }
            return observed == featureIssueID
        }
        guard let mostRecentNightID = matching.compactMap(\.nightID).max() else { return nil }
        let named = matching.filter { $0.nightID == mostRecentNightID }.compactMap { record -> String? in
            guard case .mainlineConflictDetected(_, let repository, let paths) = record.event,
                unmerged.contains(repository)
            else {
                return nil
            }
            let pathText = paths.isEmpty ? "paths unavailable" : paths.joined(separator: ", ")
            return "`\(repository)` (\(pathText))"
        }
        guard !named.isEmpty else { return nil }
        return "unmerged Feature Branches with a Mainline Conflict: \(named.joined(separator: "; "))"
    }
}
