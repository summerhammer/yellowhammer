import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
@testable import Journal
import Testing

// morning-report/write-the-night-summary (roadmap P23.6): the verdict counts every Feature a Night landed,
// and the standing line lists each Feature in the Unmerged Feature Stack U with the Nights it has awaited
// merge, `k of N`, its conflicts (`#stacked-conflicts`) and its place in the stack.
// Reuses `NightCardJournalFixture` from NightCardTests.swift.

private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

private struct SeededFeature {
    let featureID: Int64
    let cycleID: Int64
}

/// A verified, landed Feature: Cycle archived and landed, one `feature_repository` row per pushed repository.
private func seedUnmerged(
    _ journal: JournalStore, issueID: String, pushing repositories: [String], landedIn night: NightRecord
) throws -> SeededFeature {
    let seeded: SeededFeature = try journal.write { db in
        let stamp = JournalStore.timestamp(epoch)
        try db.execute(
            sql: "INSERT INTO feature (issue_id, state, created_at, closed_by) VALUES (?, ?, ?, ?)",
            arguments: [issueID, "closed", stamp, "verification"]
        )
        let featureID = db.lastInsertedRowID
        try db.execute(
            sql: "INSERT INTO cycle (feature_id, created_at, archived_at, landed_at) VALUES (?, ?, ?, ?)",
            arguments: [featureID, stamp, stamp, stamp]
        )
        let cycleID = db.lastInsertedRowID
        for repository in repositories {
            try db.execute(
                sql: "INSERT INTO feature_repository (feature_id, repository, branch) VALUES (?, ?, ?)",
                arguments: [featureID, repository, "yh/\(issueID.lowercased())"]
            )
            try db.execute(
                sql: """
                INSERT INTO pushed_tip (cycle_id, repository, "commit", run_id, pushed_at) VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [cycleID, repository, "commit-\(issueID)", RunID().rawValue, stamp]
            )
        }
        return SeededFeature(featureID: featureID, cycleID: cycleID)
    }
    try journal.append(.cycleLanded(cycleID: seeded.cycleID), act: .land, runID: RunID(), nightID: night.id)
    return seeded
}

private func openNight(_ journal: JournalStore, _ start: String) async throws -> NightRecord {
    try await EngineInvocation(
        act: .author, mode: .real, nightStart: try #require(NightStart(rawValue: start)), journal: journal,
        trigger: .forced, runID: RunID(), work: { _ in }
    ).run()
    return try #require(try journal.currentNight())
}

@Suite("Night Summary: several Features landed, and the Unmerged Feature Stack standing line (P23.6)")
struct NightSummaryUnmergedStackTests {
    @Test("A Night with two cycleLanded events counts both in the verdict, constant-time")
    func verdictCountsEveryLandedFeature() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let night = try await openNight(journal, "2026-09-15")
        _ = try seedUnmerged(journal, issueID: "FEAT-1", pushing: ["repo-a"], landedIn: night)
        _ = try seedUnmerged(journal, issueID: "FEAT-2", pushing: ["repo-a"], landedIn: night)

        let verdict = try NightSummary.verdictLine(night: night, journal: journal)

        #expect(verdict.contains("2 Features landed, 2 awaiting merge"))
        #expect(!verdict.contains("FEAT-"))
    }

    @Test("A Night with one landed Feature keeps the single-Feature wording")
    func verdictWithOneLandedFeature() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let night = try await openNight(journal, "2026-09-15")
        _ = try seedUnmerged(journal, issueID: "FEAT-1", pushing: ["repo-a"], landedIn: night)

        let verdict = try NightSummary.verdictLine(night: night, journal: journal)

        #expect(verdict.contains(" landed · ") || verdict.hasSuffix(" landed"))
        #expect(!verdict.contains("Features landed"))
    }

    @Test("One entry per Feature in U, oldest first, with Nights awaited, k of N, the stack and a shared conflict")
    func standingLinePerUnmergedFeature() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let night1 = try await openNight(journal, "2026-09-15")
        let first = try seedUnmerged(journal, issueID: "FEAT-1", pushing: ["repo-a", "repo-b"], landedIn: night1)
        let night2 = try await openNight(journal, "2026-09-16")
        _ = try seedUnmerged(journal, issueID: "FEAT-2", pushing: ["repo-a"], landedIn: night2)
        try journal.recordLanding(
            featureID: first.featureID, repository: "repo-b", landingCommit: "m",
            mainlineCommit: "m", evidence: .ancestry
        )
        try journal.append(
            .pullRequestStacked(
                featureIssueID: "FEAT-2", repository: "repo-a", predecessorFeatureIssueID: "FEAT-1",
                predecessorBranch: "yh/feat-1", predecessorPullRequestURL: "https://example.test/pull/41"
            ),
            act: .land, runID: RunID(), nightID: night2.id
        )
        try journal.append(
            .mainlineConflictDetected(featureIssueID: "FEAT-1", repository: "repo-a", paths: ["a.swift", "b.swift"]),
            act: .author, runID: RunID(), nightID: night2.id
        )
        try journal.append(
            .mainlineConflictDetected(
                featureIssueID: "FEAT-2", repository: "repo-a", paths: ["a.swift", "b.swift", "c.swift"]
            ),
            act: .author, runID: RunID(), nightID: night2.id
        )

        let lines = try NightSummary.inFlightFeatureLines(night: night2, journal: journal)

        #expect(lines.count == 2)
        let one = lines[0]
        #expect(one.hasPrefix("`FEAT-1` — awaiting merge for 2 Nights; 1 of 2 Feature Branches merged"))
        #expect(one.contains("`FEAT-2` is stacked on it"))
        #expect(one.contains("[conflict: repo-a] (a.swift, b.swift)"))
        let two = lines[1]
        #expect(two.hasPrefix("`FEAT-2` — awaiting merge for 1 Night; 0 of 1 Feature Branches merged"))
        #expect(two.contains("stacked on #41"))
        #expect(two.contains(
            "[conflict: repo-a] conflicts on the same paths as `FEAT-1`; "
                + "resolve that Feature first, and the next pass re-tests this one (own paths: c.swift)"
        ))
        #expect(!two.contains("same conflict"))
    }

    @Test("Every entry in U, with or without a conflict, ends with the any-method sentence and the route out (#716)")
    func everyEntryGivesTheRouteOut() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let night = try await openNight(journal, "2026-09-15")
        _ = try seedUnmerged(journal, issueID: "FEAT-1", pushing: ["repo-a"], landedIn: night)
        _ = try seedUnmerged(journal, issueID: "FEAT-2", pushing: ["repo-b"], landedIn: night)
        try journal.append(
            .mainlineConflictDetected(featureIssueID: "FEAT-2", repository: "repo-b", paths: ["a.swift"]),
            act: .author, runID: RunID(), nightID: night.id
        )

        let lines = try NightSummary.inFlightFeatureLines(night: night, journal: journal)

        let routeOut = " Merging the pull request by any method releases the next Feature. If the pull request is "
            + "already merged and the Feature is still waiting, a content-free merge of the Feature Branch into "
            + "mainline with a merge commit (`git merge -s ours`) opens the gate."
        #expect(lines.count == 2)
        for line in lines {
            #expect(line.hasSuffix(routeOut))
            #expect(line.components(separatedBy: "by any method").count == 2)
            #expect(!line.contains("Create a merge commit"))
        }
        #expect(lines[1].contains("[conflict: repo-b] (a.swift)"))
    }

    @Test("Every entry, the stacking note and the conflict attribution show identifiers, never issue ids")
    func entriesShowDisplayIdentifiers() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let night = try await openNight(journal, "2026-09-15")
        _ = try seedUnmerged(journal, issueID: "uuid-one", pushing: ["repo-a"], landedIn: night)
        _ = try seedUnmerged(journal, issueID: "uuid-two", pushing: ["repo-a"], landedIn: night)
        try journal.write { db in
            try db.execute(sql: "UPDATE feature SET issue_key = 'YLH-1' WHERE issue_id = 'uuid-one'")
            try db.execute(sql: "UPDATE feature SET issue_key = 'YLH-2' WHERE issue_id = 'uuid-two'")
        }
        try journal.append(
            .pullRequestStacked(
                featureIssueID: "uuid-two", repository: "repo-a", predecessorFeatureIssueID: "uuid-one",
                predecessorBranch: "yh/uuid-one", predecessorPullRequestURL: nil
            ),
            act: .land, runID: RunID(), nightID: night.id
        )
        for (issue, paths) in [("uuid-one", ["a.swift"]), ("uuid-two", ["a.swift", "b.swift"])] {
            try journal.append(
                .mainlineConflictDetected(featureIssueID: issue, repository: "repo-a", paths: paths),
                act: .author, runID: RunID(), nightID: night.id
            )
        }

        let text = try NightSummary.inFlightFeatureLines(night: night, journal: journal).joined(separator: "\n")

        #expect(text.contains("`YLH-1` — ") && text.contains("`YLH-2` — "))
        #expect(text.contains("stacked on `YLH-1`") && text.contains("`YLH-2` is stacked on it"))
        #expect(text.contains("conflicts on the same paths as `YLH-1`"))
        #expect(!text.contains("uuid-"))
    }

    @Test("A Feature that is not stacked keeps its own conflict paths whatever sits below it")
    func unstackedFeatureIsNotAttributed() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let night = try await openNight(journal, "2026-09-15")
        _ = try seedUnmerged(journal, issueID: "FEAT-1", pushing: ["repo-a"], landedIn: night)
        _ = try seedUnmerged(journal, issueID: "FEAT-2", pushing: ["repo-a"], landedIn: night)
        for issue in ["FEAT-1", "FEAT-2"] {
            try journal.append(
                .mainlineConflictDetected(featureIssueID: issue, repository: "repo-a", paths: ["a.swift"]),
                act: .author, runID: RunID(), nightID: night.id
            )
        }

        let lines = try NightSummary.inFlightFeatureLines(night: night, journal: journal)

        #expect(lines.count == 2)
        #expect(lines[1].contains("[conflict: repo-a] (a.swift)"))
        #expect(!lines[1].contains("same paths"))
    }
}
