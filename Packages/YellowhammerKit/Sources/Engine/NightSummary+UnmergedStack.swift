import Domain
import Foundation
import Journal

// The standing line's entries for the Unmerged Feature Stack U (roadmap P23.6; spec:
// morning-report/write-the-night-summary, the standing line and `#stacked-conflicts`): each verified,
// landed Feature awaiting merge, oldest first, with how many Nights it has awaited merge, `k of N`, its
// conflicts, its place in the stack and its notes, the pull request read's among them (#714), then the route out
// (#716). Derived from the Journal at read time; reported only.

extension NightSummary {
    /// One entry per Feature in U, in `journal.unmergedFeatureStack()`'s order (Feature id ascending).
    static func unmergedStackLines(night: NightRecord, journal: JournalStore) throws -> [String] {
        let stack = try journal.unmergedFeatureStack()
        guard !stack.isEmpty else { return [] }
        let stackings = try stackings(journal: journal)
        var conflictsBelow: [(identifier: String, conflicts: [String: [String]])] = []
        var below: [UnmergedFeature] = []
        var lines: [String] = []
        for member in stack {
            let issueID = member.feature.issueID
            let observation = try FeatureMainlineObservationReader.latestAncestryObservation(
                featureIssueID: issueID, journal: journal
            )
            let conflicts = try FeatureMainlineObservationReader.conflicts(
                featureIssueID: issueID, unmergedRepositories: observation?.unmerged ?? member.unmergedRepositories,
                journal: journal
            )
            let awaited = try awaitedPhrase(
                member, night: night, journal: journal, indeterminate: observation?.indeterminate.isEmpty == false
            )
            var line = "`\(member.feature.displayIdentifier)` — " + awaited + "; "
                + "\(member.mergedRepositories.count) of \(member.pushedRepositories.count) Feature Branches merged"
            let indeterminateNotes = PredecessorIndeterminateDescription.notes(observation?.indeterminate ?? [:])
            if !indeterminateNotes.isEmpty { line += "; " + indeterminateNotes }
            if let note = try stackingNote(issueID: issueID, stackings: stackings, journal: journal) {
                line += "; \(note)"
            }
            if !conflicts.isEmpty {
                let stacked = try isStacked(member, stackings: stackings, journal: journal)
                let named = conflicts.keys.sorted().map { repository in
                    conflictPhrase(
                        repository: repository, paths: conflicts[repository] ?? [],
                        below: stacked ? conflictsBelow : []
                    )
                }
                line += "; " + named.joined(separator: "; ")
            }
            let noPullRequest = try journal.noPushedBranchRepositories(featureID: member.feature.id)
            if !noPullRequest.isEmpty { line += " " + FeatureRollUp.noPullRequestNotes(noPullRequest) }
            let readNotes = try pullRequestReadNotes(
                featureID: member.feature.id, unmergedRepositories: member.unmergedRepositories,
                pushedTips: member.pushedTips, lowerBranches: lowerFeatureBranches(below), journal: journal
            )
            if !readNotes.isEmpty { line += " " + readNotes.joined(separator: " ") }
            line += try FeatureCancellationAnnotation.suffix(
                featureID: member.feature.id, issueID: issueID, journal: journal
            )
            lines.append(line + " " + routeOut(observation))
            conflictsBelow.append((member.feature.displayIdentifier, conflicts))
            below.append(member)
        }
        return lines
    }

    private static func routeOut(_ observation: FeatureMainlineObservation?) -> String {
        observation?.indeterminate.isEmpty == false
            ? "The merge observation is retried on a later author Act." : MergeRouteOut.nightCard
    }

    private static func isStacked(
        _ member: UnmergedFeature, stackings: Stackings, journal: JournalStore
    ) throws -> Bool {
        if stackings.stackedOn[member.feature.issueID] != nil { return true }
        return try journal.featureBases(featureID: member.feature.id).contains { $0.stackedOnFeatureID != nil }
    }

    /// `awaiting merge for <n> Night(s)`, counted from the Night of the Feature's `cycleLanded` event.
    private static func awaitedPhrase(
        _ member: UnmergedFeature, night: NightRecord, journal: JournalStore, indeterminate: Bool
    ) throws -> String {
        guard let landedNight = try journal.landedNightID(featureID: member.feature.id),
            let awaited = try journal.nightsHeld(selectedNightID: landedNight, asOf: night.nightStart)
        else {
            return "the Night it landed is not recorded"
        }
        let standing = indeterminate ? "awaiting merge observation" : "awaiting merge"
        return "\(standing) for \(awaited) Night\(awaited == 1 ? "" : "s")"
    }

    /// `[conflict: <repo>] (<paths>)`; where a Feature below it in the stack conflicts on a subset of the same
    /// paths in that repository, the lowest such Feature is named and only the extra paths are listed.
    /// Matching paths do not prove the same conflict, so the wording never says "same conflict".
    private static func conflictPhrase(
        repository: String, paths: [String], below: [(identifier: String, conflicts: [String: [String]])]
    ) -> String {
        let own = Set(paths)
        guard let lowest = below.first(where: { entry in
            let theirs = Set(entry.conflicts[repository] ?? [])
            return !theirs.isEmpty && theirs.isSubset(of: own)
        }) else {
            let text = paths.isEmpty ? "paths unavailable" : paths.joined(separator: ", ")
            return "[conflict: \(repository)] (\(text))"
        }
        let extra = paths.filter { !(lowest.conflicts[repository] ?? []).contains($0) }
        var phrase = "[conflict: \(repository)] conflicts on the same paths as `\(lowest.identifier)`; "
            + "resolve that Feature first, and the next pass re-tests this one"
        if !extra.isEmpty { phrase += " (own paths: \(extra.joined(separator: ", ")))" }
        return phrase
    }

    /// What the `pullRequestStacked` events say about the stack: which Feature each Feature's pull request is
    /// stacked on (with that predecessor's pull request number, when recorded), and which Features are
    /// stacked on each Feature.
    private struct Stackings {
        var stackedOn: [String: (predecessor: String, pullRequest: String?)] = [:]
        var dependents: [String: [String]] = [:]
    }

    private static func stackings(journal: JournalStore) throws -> Stackings {
        var result = Stackings()
        for record in try journal.events(ofType: .pullRequestStacked) {
            guard case .pullRequestStacked(let issue, _, let predecessor, _, let url) = record.event else { continue }
            let number = url.flatMap { $0.split(separator: "/").last.map(String.init) }.flatMap { Int($0) }
            result.stackedOn[issue] = (predecessor, number.map { "#\($0)" })
            if !(result.dependents[predecessor] ?? []).contains(issue) {
                result.dependents[predecessor, default: []].append(issue)
            }
        }
        return result
    }

    private static func stackingNote(issueID: String, stackings: Stackings, journal: JournalStore) throws -> String? {
        var notes: [String] = []
        if let below = stackings.stackedOn[issueID] {
            let predecessor = try featureIdentifier(issueID: below.predecessor, journal: journal)
            notes.append("stacked on \(below.pullRequest ?? "`\(predecessor)`")")
        }
        for dependent in stackings.dependents[issueID] ?? [] {
            notes.append("`\(try featureIdentifier(issueID: dependent, journal: journal))` is stacked on it")
        }
        return notes.isEmpty ? nil : notes.joined(separator: "; ")
    }

    /// The Feature's ``FeatureRecord/displayIdentifier`` (e.g. `YLH-325`); the raw issue id only when the
    /// Journal holds no such Feature. Standing lines never print a Linear UUID where a record exists.
    static func featureIdentifier(issueID: String, journal: JournalStore) throws -> String {
        try journal.feature(issueID: issueID)?.displayIdentifier ?? issueID
    }
}
