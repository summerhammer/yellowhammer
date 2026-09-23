import Domain
import Journal

/// The predecessor-ancestry gate's latest read of a Feature's mainline standing (roadmap P9.2/P9.9),
/// shared by the Night Summary's `**Standing: unmerged in-flight Feature:**` line (roadmap P12.1) and
/// the Feature Roll-up (roadmap P12.3), so the two can never disagree about what the gate last found.
public struct FeatureMainlineObservation: Equatable, Sendable {
    /// Repositories `predecessorAncestryObserved` most recently found the Feature Branch merged into.
    public let merged: [String]
    /// Repositories `predecessorAncestryObserved` most recently found still unmerged.
    public let unmerged: [String]
}

public enum FeatureMainlineObservationReader {
    /// The latest `predecessorAncestryObserved` pass for `featureIssueID`, nil when none has run yet.
    public static func latestAncestryObservation(
        featureIssueID: String, journal: JournalStore
    ) throws -> FeatureMainlineObservation? {
        let events = try journal.events(ofType: .predecessorAncestryObserved)
        guard let latest = events.last(where: { record in
            guard case .predecessorAncestryObserved(let observed, _, _) = record.event else { return false }
            return observed == featureIssueID
        }), case .predecessorAncestryObserved(_, let merged, let unmerged) = latest.event else {
            return nil
        }
        return FeatureMainlineObservation(merged: merged, unmerged: unmerged)
    }

    /// Which of `unmergedRepositories` carry a Mainline Conflict, from the most recent Night that
    /// recorded any `mainlineConflictDetected` event for `featureIssueID` — not necessarily this call's
    /// own Night, since both callers read a standing fact. Keyed by repository, valued by the changed
    /// paths the conflict named; empty when there is nothing to report.
    public static func conflicts(
        featureIssueID: String, unmergedRepositories: [String], journal: JournalStore
    ) throws -> [String: [String]] {
        guard !unmergedRepositories.isEmpty else { return [:] }
        let unmerged = Set(unmergedRepositories)
        let matching = try journal.events(ofType: .mainlineConflictDetected).filter { record in
            guard case .mainlineConflictDetected(let observed, _, _) = record.event else { return false }
            return observed == featureIssueID
        }
        guard let mostRecentNightID = matching.compactMap(\.nightID).max() else { return [:] }
        var result: [String: [String]] = [:]
        for record in matching where record.nightID == mostRecentNightID {
            guard case .mainlineConflictDetected(_, let repository, let paths) = record.event,
                unmerged.contains(repository)
            else {
                continue
            }
            result[repository] = paths
        }
        return result
    }
}
