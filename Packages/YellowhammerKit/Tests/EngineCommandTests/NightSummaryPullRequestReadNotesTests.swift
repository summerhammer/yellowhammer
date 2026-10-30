import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
@testable import Journal
import Testing

// morning-report/write-the-night-summary `#pull-request-read-notes` and `#unmerged-standing-line`;
// feature-authoring/select-the-next-feature `#pull-request-read` ("A failed read is not a failure", "What it reports
// and never acts on"); OQ190 items 12, 13, 19 and 28 (issue #714). A failed read is noted once per repository, as a
// failed mainline fetch is, and is never a failure. The standing line names a pull request closed without merge and
// one merged into a lower Feature's branch, waiting for it. A merged pull request whose head is not the Pushed Tip
// is not reported. The Night Summary names a Feature Branch with more than one pull request. None of these is a gate
// input. Reuses `NightCardJournalFixture` from NightCardTests.swift.

private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

/// A verified, landed Feature in U: Cycle archived and landed, one `feature_repository` row per pushed repository
/// on `yh/<issue id>`, whose Pushed Tip is `commit-<issue id>`.
@discardableResult
private func seedUnmerged(
    _ journal: JournalStore, issueID: String, pushing repositories: [String], landedIn night: NightRecord
) throws -> Int64 {
    let seeded: (featureID: Int64, cycleID: Int64) = try journal.write { db in
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
                arguments: [featureID, repository, branch(issueID)]
            )
            try db.execute(
                sql: """
                INSERT INTO pushed_tip (cycle_id, repository, "commit", run_id, pushed_at) VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [cycleID, repository, tip(issueID), RunID().rawValue, stamp]
            )
        }
        return (featureID, cycleID)
    }
    try journal.append(.cycleLanded(cycleID: seeded.cycleID), act: .land, runID: RunID(), nightID: night.id)
    return seeded.featureID
}

private func branch(_ issueID: String) -> String { "yh/\(issueID.lowercased())" }

private func tip(_ issueID: String) -> String { "commit-\(issueID)" }

/// A pull request as a read observed it.
private func observed(
    _ number: Int, _ state: ObservedPullRequestState, head: String, base: String, mergeCommit: String? = nil
) -> ObservedPullRequest {
    ObservedPullRequest(
        number: number, url: "https://github.com/o/r/pull/\(number)", state: state, mergeCommit: mergeCommit,
        headCommit: head, headBranch: "yh/feature", baseBranch: base
    )
}

/// Records the land Act's pull request for `repository` with no URL, and what the latest read observed on it, as
/// the gate's `recordObservedPullRequest` writes it.
private func seedObserved(
    _ journal: JournalStore, featureID: Int64, repository: String, night: NightRecord,
    _ pullRequest: ObservedPullRequest
) throws {
    try journal.recordPullRequest(
        featureID: featureID, repository: repository, url: nil, nightID: night.id, runID: RunID(), now: epoch
    )
    try journal.write { db in
        try db.execute(
            sql: """
            UPDATE pull_request SET observed_state = ?, observed_at = ?, number = ?, head_commit = ?, merge_commit = ?,
                base_branch = ?
            WHERE feature_id = ? AND repository = ?
            """,
            arguments: [
                pullRequest.state.rawValue, JournalStore.timestamp(epoch), pullRequest.number, pullRequest.headCommit,
                pullRequest.mergeCommit, pullRequest.baseBranch, featureID, repository
            ]
        )
    }
}

private func openNight(_ journal: JournalStore, _ start: String) async throws -> NightRecord {
    try await EngineInvocation(
        act: .author, mode: .real, nightStart: try #require(NightStart(rawValue: start)), journal: journal,
        trigger: .forced, runID: RunID(), work: { _ in }
    ).run()
    return try #require(try journal.currentNight())
}

@Suite("Night Summary: the pull request read's own notes (#714)")
struct NightSummaryPullRequestReadNotesTests {
    @Test("""
        A failed read is noted once per repository however many passes failed, with its reasons, and is \
        neither a failure line nor in the verdict
        """)
    func failedReadIsNotedOncePerRepository() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let night = try await openNight(journal, "2026-09-15")
        let firstPass = RunID()
        let secondPass = RunID()
        for (repository, reason, run) in [
            ("backend", PullRequestReadFailure.Reason.rateLimited, firstPass),
            ("mobile", .unreachable, firstPass),
            ("backend", .rateLimited, secondPass),
            ("backend", .credentialRefused, secondPass)
        ] {
            try journal.append(
                .pullRequestReadFailed(repository: repository, reason: reason), act: .author, runID: run,
                nightID: night.id
            )
        }

        let lines = try NightSummary.exceptionLines(night: night, journal: journal)
            .filter { $0.hasPrefix("Reading the pull request") }

        #expect(lines == [
            "Reading the pull request in `backend` failed: rate limited; the credential was refused. "
                + "Not a failure: the merge test went on without it.",
            "Reading the pull request in `mobile` failed: Code Hosting could not be reached. "
                + "Not a failure: the merge test went on without it."
        ])
        #expect(try NightSummary.failureLines(night: night, journal: journal).isEmpty)
        let verdict = try NightSummary.verdictLine(night: night, journal: journal)
        #expect(verdict.hasSuffix(" · closed"))
        #expect(!verdict.contains("pull request"))
    }

    @Test("""
        The standing line names a pull request closed without merge and one merged into a lower Feature's \
        branch as waiting for it; the lower Feature's own entry carries neither
        """)
    func closedAndWaitingNotesOnTheStandingLine() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let night1 = try await openNight(journal, "2026-09-15")
        try seedUnmerged(journal, issueID: "FEAT-1", pushing: ["repo-a"], landedIn: night1)
        let night2 = try await openNight(journal, "2026-09-16")
        let upper = try seedUnmerged(journal, issueID: "FEAT-2", pushing: ["repo-a", "repo-b"], landedIn: night2)
        try seedObserved(
            journal, featureID: upper, repository: "repo-a", night: night2,
            observed(8, .merged, head: tip("FEAT-2"), base: branch("FEAT-1"), mergeCommit: "merge-into-lower")
        )
        try seedObserved(
            journal, featureID: upper, repository: "repo-b", night: night2,
            observed(9, .closedWithoutMerge, head: tip("FEAT-2"), base: "main")
        )

        let lines = try NightSummary.inFlightFeatureLines(night: night2, journal: journal)

        #expect(lines.count == 2)
        #expect(!lines[0].contains("[closed without merge"))
        #expect(!lines[0].contains("waiting for it"))
        #expect(lines[1].hasPrefix("`FEAT-2` — awaiting merge for 1 Night; 0 of 2 Feature Branches merged"))
        #expect(lines[1].contains("[merged into yh/feat-1, waiting for it: repo-a]"))
        #expect(lines[1].contains("[closed without merge: repo-b]"))
    }

    @Test("A merged pull request whose head is not the Pushed Tip is not reported, into mainline or a lower branch")
    func mergedWithAnotherHeadIsNotReported() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let night1 = try await openNight(journal, "2026-09-15")
        try seedUnmerged(journal, issueID: "FEAT-1", pushing: ["repo-a"], landedIn: night1)
        let night2 = try await openNight(journal, "2026-09-16")
        let upper = try seedUnmerged(journal, issueID: "FEAT-2", pushing: ["repo-a", "repo-b"], landedIn: night2)
        try seedObserved(
            journal, featureID: upper, repository: "repo-a", night: night2,
            observed(8, .merged, head: "operator-commit", base: branch("FEAT-1"), mergeCommit: "merge-into-lower")
        )
        try seedObserved(
            journal, featureID: upper, repository: "repo-b", night: night2,
            observed(9, .merged, head: "operator-commit", base: "main", mergeCommit: "squash")
        )

        let line = try #require(try NightSummary.inFlightFeatureLines(night: night2, journal: journal).last)

        #expect(line.hasPrefix("`FEAT-2` — "))
        #expect(!line.contains("waiting for it"))
        #expect(!line.contains("[merged"))
        #expect(!line.contains("[closed without merge"))
    }

    @Test("""
        No note for a repository with an Observed Merge, for an open pull request, or for one merged into a branch \
        no lower Feature has
        """)
    func notesOnlyWhatTheOperatorHasToActOn() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let night = try await openNight(journal, "2026-09-15")
        let feature = try seedUnmerged(
            journal, issueID: "FEAT-1", pushing: ["repo-a", "repo-b", "repo-c"], landedIn: night
        )
        try seedObserved(
            journal, featureID: feature, repository: "repo-a", night: night,
            observed(1, .closedWithoutMerge, head: tip("FEAT-1"), base: "main")
        )
        try journal.recordLanding(
            featureID: feature, repository: "repo-a", landingCommit: "m", mainlineCommit: "m", evidence: .ancestry
        )
        try seedObserved(
            journal, featureID: feature, repository: "repo-b", night: night,
            observed(2, .open, head: tip("FEAT-1"), base: "main")
        )
        try seedObserved(
            journal, featureID: feature, repository: "repo-c", night: night,
            observed(3, .merged, head: tip("FEAT-1"), base: "main", mergeCommit: "not-yet-fetched")
        )

        let line = try #require(try NightSummary.inFlightFeatureLines(night: night, journal: journal).first)

        #expect(line.hasPrefix("`FEAT-1` — awaiting merge for 1 Night; 1 of 3 Feature Branches merged"))
        #expect(!line.contains("[closed without merge"))
        #expect(!line.contains("[merged"))
    }

    @Test("The in-flight Partial Landing's line names its pull request closed without merge too")
    func inFlightPartialLandingCarriesTheNote() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let night = try await openNight(journal, "2026-09-15")
        let featureID: Int64 = try journal.write { db in
            let stamp = JournalStore.timestamp(epoch)
            try db.execute(
                sql: "INSERT INTO feature (issue_id, selected_night_id, state, created_at) VALUES (?, ?, ?, ?)",
                arguments: ["FEAT-9", night.id, "selected", stamp]
            )
            let featureID = db.lastInsertedRowID
            try db.execute(
                sql: "INSERT INTO cycle (feature_id, created_at, landed_at) VALUES (?, ?, ?)",
                arguments: [featureID, stamp, stamp]
            )
            let cycleID = db.lastInsertedRowID
            try db.execute(
                sql: "INSERT INTO feature_repository (feature_id, repository, branch) VALUES (?, ?, ?)",
                arguments: [featureID, "backend", branch("FEAT-9")]
            )
            try db.execute(
                sql: """
                INSERT INTO pushed_tip (cycle_id, repository, "commit", run_id, pushed_at) VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [cycleID, "backend", tip("FEAT-9"), RunID().rawValue, stamp]
            )
            return featureID
        }
        try seedObserved(
            journal, featureID: featureID, repository: "backend", night: night,
            observed(5, .closedWithoutMerge, head: tip("FEAT-9"), base: "main")
        )

        let line = try #require(try NightSummary.inFlightFeatureLines(night: night, journal: journal).last)

        #expect(line.hasPrefix("`FEAT-9` — in flight for"))
        #expect(line.hasSuffix("[closed without merge: backend]"))
    }

    @Test("A Feature Branch with more than one pull request is named once, with its pull requests")
    func duplicatePullRequestsAreNamed() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let night = try await openNight(journal, "2026-09-15")
        for _ in 0..<2 {
            try journal.append(
                .multiplePullRequestsObserved(repository: "backend", branch: "yh/feat-1", numbers: [4, 7]),
                act: .author, runID: RunID(), nightID: night.id
            )
        }

        let lines = try NightSummary.pullRequestLines(night: night, journal: journal)

        #expect(lines == ["`backend`: Feature Branch `yh/feat-1` has more than one pull request: #4, #7."])
        #expect(try NightSummary.failureLines(night: night, journal: journal).isEmpty)
    }

    @Test("A pull request recorded without a URL is listed by the number the read found")
    func pullRequestListFallsBackToTheNumber() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let night = try await openNight(journal, "2026-09-15")
        let feature = try seedUnmerged(journal, issueID: "FEAT-1", pushing: ["backend", "mobile"], landedIn: night)
        try seedObserved(
            journal, featureID: feature, repository: "backend", night: night,
            observed(7, .open, head: tip("FEAT-1"), base: "main")
        )
        try journal.recordPullRequest(
            featureID: feature, repository: "mobile", url: nil, nightID: night.id, runID: RunID(), now: epoch
        )

        let lines = try NightSummary.pullRequestLines(night: night, journal: journal)

        #expect(lines.contains("`backend`: #7"))
        #expect(lines.contains("`mobile`: no url recorded"))
    }
}
