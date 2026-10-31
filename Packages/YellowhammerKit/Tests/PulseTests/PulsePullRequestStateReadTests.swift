import Domain
import Foundation
import Testing

@testable import Journal
@testable import Pulse

// app/land-on-the-sidebar-and-pulse `#pull-request-state` (OQ190 items 4, 17 and 18): each repository's entry in
// Awaiting merge shows its pull request's last observed state, with the time it was observed, as the engine's pull
// request read recorded it in the Journal. A failed latest read keeps the state and says so; a state never observed
// shows none; and the state sits beside "in mainline", never instead of it.

private struct StateFixture: ~Copyable {
    let directory = FileManager.default.temporaryDirectory.appending(component: "yh-pulse-pr-state-\(UUID())")
    let projectID = ProjectID(rawValue: "fixture")! // swiftlint:disable:this force_unwrapping

    deinit { try? FileManager.default.removeItem(at: directory) }

    func open() throws -> JournalStore {
        try JournalStore.open(configurationDirectory: directory, projectID: projectID)
    }
}

/// A real Night opened under a land Act's lease, which every observation and failure below is recorded under.
private struct StateNight {
    let nightID: Int64
    let run: RunID

    init(_ journal: JournalStore) throws {
        run = RunID()
        _ = try journal.claimActLease(act: .land, runID: run, mode: .real, now: epoch)
        nightID = try journal.openNight(nightStart: nightStart, mode: .real, act: .land, runID: run, now: epoch)
            .night.id
    }
}

/// A landed, archived Feature in U that pushed in `repositories`, with a pull request recorded in each: by URL
/// `https://github.com/acme/<repo>/pull/<number>`, or by none when `withURL` is false (the "already exists" path).
private func seedAwaiting(
    _ journal: JournalStore, night: StateNight, issueID: String = "feature-1", repositories: [String: Int],
    withURL: Bool = true
) throws -> Int64 {
    let feature = try insertFeature(journal, issueID: issueID)
    try journal.write { db in
        try db.execute(
            sql: "UPDATE feature SET state = 'closed', closed_by = 'verification' WHERE id = ?",
            arguments: [feature.featureID]
        )
        try db.execute(
            sql: "UPDATE cycle SET landed_at = ?, archived_at = ? WHERE id = ?",
            arguments: [JournalStore.timestamp(epoch), JournalStore.timestamp(epoch), feature.cycleID]
        )
    }
    for (repository, number) in repositories {
        try journal.recordFeatureBranch(
            featureID: feature.featureID, repository: repository, branch: FeatureBranch(rawValue: "yh/\(issueID)")
        )
        try journal.recordPullRequest(
            featureID: feature.featureID, repository: repository,
            url: withURL ? "https://github.com/acme/\(repository)/pull/\(number)" : nil,
            nightID: night.nightID, runID: night.run, now: epoch.addingTimeInterval(1)
        )
    }
    try journal.append(
        .cycleLanded(cycleID: feature.cycleID), act: .land, runID: night.run, nightID: night.nightID,
        now: epoch.addingTimeInterval(1)
    )
    return feature.featureID
}

/// Which pull request a successful read observed: `featureID`'s pull request `number` in `repository`.
private struct Read {
    let featureID: Int64
    let repository: String
    let number: Int

    init(_ featureID: Int64, _ repository: String, _ number: Int) {
        self.featureID = featureID
        self.repository = repository
        self.number = number
    }
}

private func observe(
    _ journal: JournalStore, night: StateNight, _ read: Read, state: ObservedPullRequestState, at offset: Double
) throws {
    let (featureID, repository, number) = (read.featureID, read.repository, read.number)
    let observed = ObservedPullRequest(
        number: number, url: "https://github.com/acme/\(repository)/pull/\(number)", state: state,
        mergeCommit: state == .merged ? "merge-\(number)" : nil, headCommit: "tip-\(number)",
        headBranch: "yh/feature", baseBranch: "main"
    )
    #expect(try journal.recordObservedPullRequest(
        featureID: featureID, repository: repository, observed: observed, runID: night.run,
        now: epoch.addingTimeInterval(offset)
    ))
}

private func failRead(_ journal: JournalStore, night: StateNight, repository: String, at offset: Double) throws {
    try journal.append(
        .pullRequestReadFailed(repository: repository, reason: .unreachable), act: .land, runID: night.run,
        nightID: night.nightID, now: epoch.addingTimeInterval(offset)
    )
}

private func awaitingRepositories(_ journal: JournalStore) throws -> [String: AwaitingMergeRepository] {
    let pulse = try PulseSnapshot.read(from: journal, status: .idle, asOf: epoch.addingTimeInterval(1_000))
    let repositories = pulse.unmergedFeatures.features.flatMap(\.repositories)
    return Dictionary(uniqueKeysWithValues: repositories.map { ($0.repo, $0) })
}

@Test("Each recorded state is shown with the time it was observed", arguments: ObservedPullRequestState.allCases)
func observedStateIsShownWithItsTime(state: ObservedPullRequestState) throws {
    let fixture = StateFixture()
    let journal = try fixture.open()
    let night = try StateNight(journal)
    let featureID = try seedAwaiting(journal, night: night, repositories: ["backend": 7])
    try observe(journal, night: night, Read(featureID, "backend", 7), state: state, at: 60)

    let backend = try #require(try awaitingRepositories(journal)["backend"])

    #expect(backend.pullRequestObservation == PullRequestObservation(
        state: state, observedAt: epoch.addingTimeInterval(60), latestReadFailed: false
    ))
}

@Test("A failed read after the last observation keeps the state and its time, and says the latest read failed")
func failedReadKeepsTheLastState() throws {
    let fixture = StateFixture()
    let journal = try fixture.open()
    let night = try StateNight(journal)
    let featureID = try seedAwaiting(journal, night: night, repositories: ["backend": 7])
    try observe(journal, night: night, Read(featureID, "backend", 7), state: .open, at: 60)
    try failRead(journal, night: night, repository: "backend", at: 120)

    let backend = try #require(try awaitingRepositories(journal)["backend"])

    #expect(backend.pullRequestObservation == PullRequestObservation(
        state: .open, observedAt: epoch.addingTimeInterval(60), latestReadFailed: true
    ))
}

@Test("Failed reads across two Nights: the latest failure date wins, whatever order they were recorded in")
func latestFailureAcrossNightsWins() throws {
    let fixture = StateFixture()
    let journal = try fixture.open()
    let night = try StateNight(journal)
    let featureID = try seedAwaiting(journal, night: night, repositories: ["backend": 7])
    try failRead(journal, night: night, repository: "backend", at: 30)
    try failRead(journal, night: night, repository: "backend", at: 60)
    try observe(journal, night: night, Read(featureID, "backend", 7), state: .open, at: 120)
    try journal.releaseActLease(runID: night.run)
    let nextRun = RunID()
    let later = epoch.addingTimeInterval(100_000)
    _ = try journal.claimActLease(act: .land, runID: nextRun, mode: .real, now: later)
    let nextNight = try journal.openNight(
        nightStart: try #require(NightStart(rawValue: "2026-09-30")), mode: .real, act: .land, runID: nextRun,
        now: later
    ).night.id
    for offset in [100_200.0, 100_100.0] {
        try journal.append(
            .pullRequestReadFailed(repository: "backend", reason: .unreachable), act: .land, runID: nextRun,
            nightID: nextNight, now: epoch.addingTimeInterval(offset)
        )
    }

    #expect(try journal.lastPullRequestReadFailures()["backend"] == epoch.addingTimeInterval(100_200))
    let backend = try #require(try awaitingRepositories(journal)["backend"])
    #expect(backend.pullRequestObservation == PullRequestObservation(
        state: .open, observedAt: epoch.addingTimeInterval(120), latestReadFailed: true
    ))
}

@Test("A successful read after a failed one is the latest read, so nothing says it failed")
func successAfterFailureClearsTheMark() throws {
    let fixture = StateFixture()
    let journal = try fixture.open()
    let night = try StateNight(journal)
    let featureID = try seedAwaiting(journal, night: night, repositories: ["backend": 7])
    try observe(journal, night: night, Read(featureID, "backend", 7), state: .open, at: 60)
    try failRead(journal, night: night, repository: "backend", at: 120)
    try observe(journal, night: night, Read(featureID, "backend", 7), state: .closedWithoutMerge, at: 180)

    let backend = try #require(try awaitingRepositories(journal)["backend"])

    #expect(backend.pullRequestObservation == PullRequestObservation(
        state: .closedWithoutMerge, observedAt: epoch.addingTimeInterval(180), latestReadFailed: false
    ))
}

@Test("A failed read in another repository does not mark this one")
func failureInAnotherRepositoryDoesNotMark() throws {
    let fixture = StateFixture()
    let journal = try fixture.open()
    let night = try StateNight(journal)
    let featureID = try seedAwaiting(journal, night: night, repositories: ["backend": 7, "web": 8])
    try observe(journal, night: night, Read(featureID, "backend", 7), state: .open, at: 60)
    try observe(journal, night: night, Read(featureID, "web", 8), state: .open, at: 60)
    try failRead(journal, night: night, repository: "web", at: 120)

    let shown = try awaitingRepositories(journal)

    #expect(shown["backend"]?.pullRequestObservation?.latestReadFailed == false)
    #expect(shown["web"]?.pullRequestObservation?.latestReadFailed == true)
}

@Test("A pull request last observed merged is not read again, so a later failed read never marks it")
func mergedIsFinal() throws {
    let fixture = StateFixture()
    let journal = try fixture.open()
    let night = try StateNight(journal)
    let featureID = try seedAwaiting(journal, night: night, repositories: ["backend": 7])
    try observe(journal, night: night, Read(featureID, "backend", 7), state: .merged, at: 60)
    try failRead(journal, night: night, repository: "backend", at: 120)

    let backend = try #require(try awaitingRepositories(journal)["backend"])

    #expect(backend.pullRequestObservation == PullRequestObservation(
        state: .merged, observedAt: epoch.addingTimeInterval(60), latestReadFailed: false
    ))
}

@Test("Where no state was ever observed the entry shows none, a failed read included")
func neverObservedShowsNone() throws {
    let fixture = StateFixture()
    let journal = try fixture.open()
    let night = try StateNight(journal)
    _ = try seedAwaiting(journal, night: night, repositories: ["backend": 7, "web": 8])
    try failRead(journal, night: night, repository: "web", at: 120)

    let shown = try awaitingRepositories(journal)

    #expect(shown["backend"]?.pullRequestObservation == nil)
    #expect(shown["web"]?.pullRequestObservation == nil)
    #expect(shown["backend"]?.pullRequest?.number == 7)
}

@Test("A pull request recorded with no URL but read by its number has a chip with the number and no link")
func numberOnlyRowGetsAChip() throws {
    let fixture = StateFixture()
    let journal = try fixture.open()
    let night = try StateNight(journal)
    let featureID = try seedAwaiting(journal, night: night, repositories: ["backend": 7], withURL: false)
    #expect(try awaitingRepositories(journal)["backend"]?.pullRequest == nil)
    try observe(journal, night: night, Read(featureID, "backend", 7), state: .open, at: 60)

    let backend = try #require(try awaitingRepositories(journal)["backend"])

    #expect(backend.pullRequest == PullRequestChip(number: 7, url: nil))
    #expect(backend.pullRequestObservation?.state == .open)
}

@Test("The state sits beside in mainline: in mainline with it open, not in mainline with it merged")
func stateNeverReplacesInMainline() throws {
    let fixture = StateFixture()
    let journal = try fixture.open()
    let night = try StateNight(journal)
    let featureID = try seedAwaiting(journal, night: night, repositories: ["backend": 7, "web": 8])
    try journal.recordLanding(
        featureID: featureID, repository: "backend", landingCommit: "m1", mainlineCommit: "m1", evidence: .content
    )
    try observe(journal, night: night, Read(featureID, "backend", 7), state: .open, at: 60)
    try observe(journal, night: night, Read(featureID, "web", 8), state: .merged, at: 60)

    let shown = try awaitingRepositories(journal)

    #expect(shown["backend"]?.merged == true)
    #expect(shown["backend"]?.pullRequestObservation?.state == .open)
    #expect(shown["web"]?.merged == false)
    #expect(shown["web"]?.pullRequestObservation?.state == .merged)
}
