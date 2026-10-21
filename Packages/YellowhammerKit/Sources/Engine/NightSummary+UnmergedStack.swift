import Domain
import Foundation
import Journal

// The standing line's entries for the Unmerged Feature Stack U (roadmap P23.6; spec:
// morning-report/write-the-night-summary, the standing line and `#stacked-conflicts`): each verified,
// landed Feature awaiting merge, oldest first, with how many Nights it has awaited merge, `k of N`, its
// conflicts, its place in the stack and its notes. Derived from the Journal at read time; reported only.
//
// The `[canceled on the Board: …]` note (board-projection/maintain-the-managed-block `#canceled-in-u-note`)
// is not rendered: the Journal records no observation of an archived Feature Card's native state, and the
// Night Summary reads no board. Rendering it needs that observation recorded first.

extension NightSummary {
    /// One entry per Feature in U, in `journal.unmergedFeatureStack()`'s order (Feature id ascending).
    static func unmergedStackLines(night: NightRecord, journal: JournalStore) throws -> [String] {
        let stack = try journal.unmergedFeatureStack()
        guard !stack.isEmpty else { return [] }
        let stackings = try stackings(journal: journal)
        var conflictsBelow: [(issueID: String, conflicts: [String: [String]])] = []
        var lines: [String] = []
        for member in stack {
            let issueID = member.feature.issueID
            let conflicts = try FeatureMainlineObservationReader.conflicts(
                featureIssueID: issueID, unmergedRepositories: member.unmergedRepositories, journal: journal
            )
            let recordedStacked = try journal.featureBases(featureID: member.feature.id)
                .contains { $0.stackedOnFeatureID != nil }
            let isStacked = stackings.stackedOn[issueID] != nil || recordedStacked
            var line = "`\(issueID)` — " + (try awaitedPhrase(member, night: night, journal: journal)) + "; "
                + "\(member.mergedRepositories.count) of \(member.pushedRepositories.count) Feature Branches merged"
            if let note = stackingNote(issueID: issueID, stackings: stackings) { line += "; \(note)" }
            if !conflicts.isEmpty {
                let named = conflicts.keys.sorted().map { repository in
                    conflictPhrase(
                        repository: repository, paths: conflicts[repository] ?? [],
                        below: isStacked ? conflictsBelow : []
                    )
                }
                line += "; " + named.joined(separator: "; ") + " " + MergeCommitRecommendation.shared
            }
            let noPullRequest = try journal.noPushedBranchRepositories(featureID: member.feature.id)
            if !noPullRequest.isEmpty { line += " " + FeatureRollUp.noPullRequestNotes(noPullRequest) }
            lines.append(line)
            conflictsBelow.append((issueID, conflicts))
        }
        return lines
    }

    /// `awaiting merge for <n> Night(s)`, counted from the Night of the Feature's `cycleLanded` event.
    private static func awaitedPhrase(
        _ member: UnmergedFeature, night: NightRecord, journal: JournalStore
    ) throws -> String {
        guard let landedNight = try journal.landedNightID(featureID: member.feature.id),
            let awaited = try journal.nightsHeld(selectedNightID: landedNight, asOf: night.nightStart)
        else {
            return "the Night it landed is not recorded"
        }
        return "awaiting merge for \(awaited) Night\(awaited == 1 ? "" : "s")"
    }

    /// `[conflict: <repo>] (<paths>)`; where a Feature below it in the stack conflicts on a subset of the same
    /// paths in that repository, the lowest such Feature is named and only the extra paths are listed.
    /// Matching paths do not prove the same conflict, so the wording never says "same conflict".
    private static func conflictPhrase(
        repository: String, paths: [String], below: [(issueID: String, conflicts: [String: [String]])]
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
        var phrase = "[conflict: \(repository)] conflicts on the same paths as `\(lowest.issueID)`; "
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

    private static func stackingNote(issueID: String, stackings: Stackings) -> String? {
        var notes: [String] = []
        if let below = stackings.stackedOn[issueID] {
            notes.append("stacked on \(below.pullRequest ?? "`\(below.predecessor)`")")
        }
        for dependent in stackings.dependents[issueID] ?? [] {
            notes.append("`\(dependent)` is stacked on it")
        }
        return notes.isEmpty ? nil : notes.joined(separator: "; ")
    }
}
