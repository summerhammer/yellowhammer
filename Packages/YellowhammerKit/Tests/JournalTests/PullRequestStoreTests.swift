import Domain
import Foundation
import GRDB
import Testing

@testable import Journal

// roadmap P10.4: the `pull_request` table records a Repo Lane's opened pull request once, unique on
// (feature_id, repository) so a first write wins and the seam above it never updates or duplicates.

private struct JournalFixture: ~Copyable {
    let directory: URL
    let projectID: ProjectID

    init(project: String = "fixture") throws {
        directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-journal-\(UUID().uuidString)", directoryHint: .isDirectory)
        projectID = try #require(ProjectID(rawValue: project))
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func open() throws -> JournalStore {
        try JournalStore.open(configurationDirectory: directory, projectID: projectID)
    }
}

private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

private func insertFixtureFeature(_ journal: JournalStore, issueID: String) throws -> Int64 {
    try journal.write { db in
        try db.execute(
            sql: "INSERT INTO feature (issue_id, state, created_at) VALUES (?, ?, ?)",
            arguments: [issueID, "selected", JournalStore.timestamp(epoch)]
        )
        return db.lastInsertedRowID
    }
}

private func insertFixtureNight(_ journal: JournalStore, projectID: ProjectID) throws -> Int64 {
    try journal.write { db in
        try db.execute(
            sql: """
            INSERT INTO night (project_id, night_start, mode, state, opened_at)
            VALUES (?, ?, ?, ?, ?)
            """,
            arguments: [projectID.rawValue, "2026-09-16", "real", "open", JournalStore.timestamp(epoch)]
        )
        return db.lastInsertedRowID
    }
}

@Suite("Pull request store (P10.4)")
struct PullRequestStoreTests {
    @Test("First recordPullRequest wins; a second call for the same feature/repository inserts nothing")
    func firstWriteWins() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let featureID = try insertFixtureFeature(journal, issueID: "FEAT-1")
        let nightID = try insertFixtureNight(journal, projectID: try #require(ProjectID(rawValue: "fixture")))
        let runID = RunID()

        let firstInserted = try journal.recordPullRequest(
            featureID: featureID, repository: "backend", url: "https://github.com/o/r/pull/1",
            nightID: nightID, runID: runID, now: epoch
        )
        #expect(firstInserted)

        let secondInserted = try journal.recordPullRequest(
            featureID: featureID, repository: "backend", url: "https://github.com/o/r/pull/2",
            nightID: nightID, runID: runID, now: epoch
        )
        #expect(!secondInserted)

        let record = try #require(try journal.pullRequest(featureID: featureID, repository: "backend"))
        #expect(record.url == "https://github.com/o/r/pull/1")
    }

    @Test("alreadyOpen records with a nil URL")
    func recordsNilURLForAlreadyOpen() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let featureID = try insertFixtureFeature(journal, issueID: "FEAT-1")
        let nightID = try insertFixtureNight(journal, projectID: try #require(ProjectID(rawValue: "fixture")))

        try journal.recordPullRequest(
            featureID: featureID, repository: "mobile", url: nil, nightID: nightID, runID: RunID(), now: epoch
        )

        let record = try #require(try journal.pullRequest(featureID: featureID, repository: "mobile"))
        #expect(record.url == nil)
    }

    @Test("pullRequests(featureID:) returns every recorded repository")
    func returnsAllRepositories() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let featureID = try insertFixtureFeature(journal, issueID: "FEAT-1")
        let nightID = try insertFixtureNight(journal, projectID: try #require(ProjectID(rawValue: "fixture")))

        try journal.recordPullRequest(
            featureID: featureID, repository: "backend", url: "https://github.com/o/r/pull/1",
            nightID: nightID, runID: RunID(), now: epoch
        )
        try journal.recordPullRequest(
            featureID: featureID, repository: "mobile", url: nil, nightID: nightID, runID: RunID(), now: epoch
        )

        let all = try journal.pullRequests(featureID: featureID)
        #expect(all.count == 2)
        #expect(all["backend"]?.url == "https://github.com/o/r/pull/1")
        #expect(all["mobile"]?.url == nil)
    }
}

// feature-authoring/select-the-next-feature #pull-request-read ("What it records"; OQ190 items 14 and 16; issue
// #717): each successful read overwrites the pull request's last observed state and when it was observed, per
// (Feature, repository). A failed read writes nothing, so the last state stays. Only a recorded pull request is
// updated: the read never inserts one.

private func observed(
    _ number: Int, state: ObservedPullRequestState, mergeCommit: String? = nil, head: String = "c0ffee",
    base: String = "main"
) -> ObservedPullRequest {
    ObservedPullRequest(
        number: number, url: "https://github.com/o/r/pull/\(number)", state: state, mergeCommit: mergeCommit,
        headCommit: head, headBranch: "yh-feature", baseBranch: base
    )
}

/// Claims the Act lease at `epoch`, as the author Act holds it while the gate reads.
private func claimLease(_ journal: JournalStore) throws -> RunID {
    let runID = RunID()
    guard case .claimed = try journal.claimActLease(act: .author, runID: runID, mode: .real, now: epoch) else {
        throw JournalError.actLeaseLost(runID: runID, holder: nil)
    }
    return runID
}

@Suite("Pull request store: the last observed state (#717)")
struct PullRequestObservedStateStoreTests {
    @Test("A recorded pull request has no observed state until a read records one")
    func neverObserved() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let featureID = try insertFixtureFeature(journal, issueID: "FEAT-1")
        let nightID = try insertFixtureNight(journal, projectID: fixture.projectID)
        try journal.recordPullRequest(
            featureID: featureID, repository: "backend", url: "https://github.com/o/r/pull/1",
            nightID: nightID, runID: RunID(), now: epoch
        )

        let record = try #require(try journal.pullRequest(featureID: featureID, repository: "backend"))
        #expect(record.observedState == nil)
        #expect(record.observedAt == nil)
        #expect(record.number == nil)
        #expect(record.headCommit == nil)
        #expect(record.mergeCommit == nil)
        #expect(record.baseBranch == nil)
    }

    @Test("A read records the state, its time, the number, the head and merge commits and the base branch")
    func recordsTheObservation() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let featureID = try insertFixtureFeature(journal, issueID: "FEAT-1")
        let nightID = try insertFixtureNight(journal, projectID: fixture.projectID)
        try journal.recordPullRequest(
            featureID: featureID, repository: "backend", url: "https://github.com/o/r/pull/1",
            nightID: nightID, runID: RunID(), now: epoch
        )
        let runID = try claimLease(journal)
        let observedAt = epoch.addingTimeInterval(60)

        let updated = try journal.recordObservedPullRequest(
            featureID: featureID, repository: "backend",
            observed: observed(1, state: .merged, mergeCommit: "5ca1ab1e", head: "c0ffee", base: "yh-lower"),
            runID: runID, now: observedAt
        )

        #expect(updated)
        let record = try #require(try journal.pullRequest(featureID: featureID, repository: "backend"))
        #expect(record.observedState == .merged)
        #expect(record.observedAt == observedAt)
        #expect(record.number == 1)
        #expect(record.headCommit == "c0ffee")
        #expect(record.mergeCommit == "5ca1ab1e")
        #expect(record.baseBranch == "yh-lower")
        #expect(record.url == "https://github.com/o/r/pull/1")
        #expect(record.openedAt == epoch)
        #expect(try journal.pullRequests(nightID: nightID).first?.observedState == .merged)
    }

    @Test("A later read overwrites the state and its time")
    func laterReadOverwrites() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let featureID = try insertFixtureFeature(journal, issueID: "FEAT-1")
        let nightID = try insertFixtureNight(journal, projectID: fixture.projectID)
        try journal.recordPullRequest(
            featureID: featureID, repository: "backend", url: "https://github.com/o/r/pull/1",
            nightID: nightID, runID: RunID(), now: epoch
        )
        let runID = try claimLease(journal)
        try journal.recordObservedPullRequest(
            featureID: featureID, repository: "backend", observed: observed(1, state: .open),
            runID: runID, now: epoch.addingTimeInterval(60)
        )

        let later = epoch.addingTimeInterval(120)
        try journal.recordObservedPullRequest(
            featureID: featureID, repository: "backend", observed: observed(1, state: .closedWithoutMerge),
            runID: runID, now: later
        )

        let record = try #require(try journal.pullRequest(featureID: featureID, repository: "backend"))
        #expect(record.observedState == .closedWithoutMerge)
        #expect(record.observedAt == later)
        #expect(record.mergeCommit == nil)
    }

    @Test("A pull request the land Act recorded without a URL keeps none; the read records its number (#714)")
    func recordsTheNumberOfAnAlreadyOpenPullRequest() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let featureID = try insertFixtureFeature(journal, issueID: "FEAT-1")
        let nightID = try insertFixtureNight(journal, projectID: fixture.projectID)
        try journal.recordPullRequest(
            featureID: featureID, repository: "backend", url: nil, nightID: nightID, runID: RunID(), now: epoch
        )
        let runID = try claimLease(journal)

        try journal.recordObservedPullRequest(
            featureID: featureID, repository: "backend", observed: observed(7, state: .open),
            runID: runID, now: epoch.addingTimeInterval(60)
        )

        let record = try #require(try journal.pullRequest(featureID: featureID, repository: "backend"))
        #expect(record.url == nil)
        #expect(record.number == 7)
    }

    @Test("A read never replaces the URL the land Act recorded")
    func keepsTheRecordedURL() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let featureID = try insertFixtureFeature(journal, issueID: "FEAT-1")
        let nightID = try insertFixtureNight(journal, projectID: fixture.projectID)
        try journal.recordPullRequest(
            featureID: featureID, repository: "backend", url: "https://github.com/o/r/pull/1",
            nightID: nightID, runID: RunID(), now: epoch
        )
        let runID = try claimLease(journal)

        try journal.recordObservedPullRequest(
            featureID: featureID, repository: "backend", observed: observed(9, state: .open),
            runID: runID, now: epoch.addingTimeInterval(60)
        )

        let record = try #require(try journal.pullRequest(featureID: featureID, repository: "backend"))
        #expect(record.url == "https://github.com/o/r/pull/1")
    }

    @Test("With no recorded pull request, a read records nothing and inserts no row")
    func neverInserts() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let featureID = try insertFixtureFeature(journal, issueID: "FEAT-1")
        let runID = try claimLease(journal)

        let updated = try journal.recordObservedPullRequest(
            featureID: featureID, repository: "backend", observed: observed(1, state: .open),
            runID: runID, now: epoch.addingTimeInterval(60)
        )

        #expect(!updated)
        #expect(try journal.pullRequests(featureID: featureID).isEmpty)
    }

    @Test("A run that no longer holds the Act lease records nothing")
    func revalidatesTheActLease() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let featureID = try insertFixtureFeature(journal, issueID: "FEAT-1")
        let nightID = try insertFixtureNight(journal, projectID: fixture.projectID)
        try journal.recordPullRequest(
            featureID: featureID, repository: "backend", url: "https://github.com/o/r/pull/1",
            nightID: nightID, runID: RunID(), now: epoch
        )
        _ = try claimLease(journal)

        #expect(throws: JournalError.self) {
            try journal.recordObservedPullRequest(
                featureID: featureID, repository: "backend", observed: observed(1, state: .open),
                runID: RunID(), now: epoch.addingTimeInterval(60)
            )
        }
        let record = try #require(try journal.pullRequest(featureID: featureID, repository: "backend"))
        #expect(record.observedState == nil)
    }
}
