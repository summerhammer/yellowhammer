import Domain
import Foundation
import Testing

@testable import Journal
@testable import Pulse

/// A throwaway configuration directory holding one Project's Journal. Removed on deinit, so a test
/// creates it in its own body: a helper returning it would delete the Journal under the caller.
private struct JournalFixture: ~Copyable {
    let directory: URL
    let projectID: ProjectID

    init(project: String = "fixture") throws {
        directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-pulse-\(UUID().uuidString)", directoryHint: .isDirectory)
        projectID = try #require(ProjectID(rawValue: project))
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func open() throws -> JournalStore {
        try JournalStore.open(configurationDirectory: directory, projectID: projectID)
    }
}

@Test("An empty Journal yields an idle Pulse with nothing else")
func emptyJournal() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()

    let pulse = try PulseSnapshot.read(from: journal, status: .idle)

    #expect(pulse.needsYou.cards.isEmpty)
    #expect(pulse.now.status == .idle)
    #expect(pulse.now.nextAct == nil)
    #expect(pulse.now.attempts.isEmpty)
    #expect(pulse.feature == nil)
    #expect(pulse.night == nil)
    #expect(pulse.health == nil)
}

@Test("Needs you holds Blocked and Waiting on You Cards only, with counts")
func needsYou() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let feature = try insertFeature(journal, issueID: "F-1")
    try insertCard(
        journal, cycleID: feature.cycleID, issueID: "C-1",
        state: .blocked, blockReason: .blockedByCheck, order: 1
    )
    try insertCard(
        journal, cycleID: feature.cycleID, issueID: "C-2",
        state: .blocked, blockReason: .blockedByCheck, order: 2
    )
    try insertCard(
        journal, cycleID: feature.cycleID, issueID: "C-3",
        state: .blocked, blockReason: .hardFailure, order: 3
    )
    try insertCard(journal, cycleID: feature.cycleID, issueID: "C-4", state: .waitingOnYou, order: 4)
    try insertCard(journal, cycleID: feature.cycleID, issueID: "C-5", state: .todo, order: 5)
    try insertCard(journal, cycleID: feature.cycleID, issueID: "C-6", state: .done, order: 6)
    try insertCard(journal, cycleID: feature.cycleID, issueID: "C-7", state: .cancelled, order: 7)

    let needsYou = try PulseSnapshot.read(from: journal, status: .idle).needsYou

    #expect(needsYou.cards.map(\.id) == ["C-1", "C-2", "C-3", "C-4"])
    #expect(needsYou.waitingOnYouCount == 1)
    #expect(needsYou.blockReasonCounts.map(\.reason) == [.blockedByCheck, .hardFailure])
    #expect(needsYou.blockReasonCounts.map(\.count) == [2, 1])
    #expect(needsYou.cards.first { $0.id == "C-4" }?.blockReason == nil)
}

@Test("The status is the one handed in, whether or not an Act Lease is held")
func statusIsHandedIn() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()

    // An alive job that holds no lease (stood down, or before it claims one) is working.
    let noLease = try PulseSnapshot.read(from: journal, status: .working)
    #expect(noLease.now.status == .working)

    // An Act that crashed holding the lease has no alive job: idle.
    _ = try journal.claimActLease(act: .build, runID: RunID(), mode: .real, now: epoch)
    let crashed = try PulseSnapshot.read(from: journal, status: .idle)
    #expect(crashed.now.status == .idle)
}

@Test("An open Attempt is a running Attempt; an ended one is not")
func runningAttempts() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let feature = try insertFeature(journal, issueID: "F-1")
    let open = try insertCard(journal, cycleID: feature.cycleID, issueID: "C-1", state: .inProgress, order: 1)
    let ended = try insertCard(journal, cycleID: feature.cycleID, issueID: "C-2", state: .inProgress, order: 2)
    let run = RunID()
    _ = try journal.claimActLease(act: .build, runID: run, mode: .real, now: epoch)

    let attempt = try journal.recordAttempt(cardID: open, route: route(), runID: run, now: epoch)
    _ = try journal.recordRound(
        attemptID: attempt.id, lens: .check, verdict: "green", requestedChanges: nil, judgedCommit: nil,
        runID: run, now: epoch
    )
    _ = try journal.recordRound(
        attemptID: attempt.id, lens: .review, verdict: "changes", requestedChanges: "fix it", judgedCommit: nil,
        runID: run, now: epoch
    )
    let other = try journal.recordAttempt(cardID: ended, route: route(), runID: run, now: epoch)
    try journal.write { db in
        try db.execute(
            sql: "UPDATE attempt SET ended_at = ? WHERE id = ?",
            arguments: [JournalStore.timestamp(epoch), other.id]
        )
    }

    let attempts = try PulseSnapshot.read(from: journal, status: .idle).now.attempts

    #expect(attempts.count == 1)
    let running = try #require(attempts.first)
    #expect(running.cardID == "C-1")
    #expect(running.route == "claude/sonnet/medium")
    #expect(running.round == 2)
    #expect(running.status == nil)
    #expect(running.startedAt == epoch)
}

@Test("A Blocked Card with no recorded Block Reason is listed but counted under none")
func blockedWithoutReason() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let feature = try insertFeature(journal, issueID: "F-1")
    try insertCard(journal, cycleID: feature.cycleID, issueID: "C-1", state: .blocked, order: 1)
    try insertCard(
        journal, cycleID: feature.cycleID, issueID: "C-2", state: .blocked, blockReason: .undecided, order: 2
    )

    let needsYou = try PulseSnapshot.read(from: journal, status: .idle).needsYou

    #expect(needsYou.cards.map(\.id) == ["C-1", "C-2"])
    #expect(needsYou.cards.first?.blockReason == nil)
    #expect(needsYou.blockReasonCounts.map(\.reason) == [.undecided])
    #expect(needsYou.waitingOnYouCount == 0)
}

@Test("Running Attempts across Repos each carry their own Repo; a held lease with no Feature lists none")
func runningAttemptsAcrossRepos() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()
    _ = try journal.claimActLease(act: .build, runID: run, mode: .real, now: epoch)

    let idleWithLease = try PulseSnapshot.read(from: journal, status: .working).now
    #expect(idleWithLease.status == .working)
    #expect(idleWithLease.attempts.isEmpty)

    let feature = try insertFeature(journal, issueID: "F-1")
    let first = try insertCard(
        journal, cycleID: feature.cycleID, issueID: "C-1", repository: "app", state: .inProgress, order: 1
    )
    let second = try insertCard(
        journal, cycleID: feature.cycleID, issueID: "C-2", repository: "api", state: .inProgress, order: 2
    )
    _ = try journal.recordAttempt(cardID: first, route: route(), runID: run, now: epoch)
    _ = try journal.recordAttempt(cardID: second, route: route(), runID: run, now: epoch)

    let attempts = try PulseSnapshot.read(from: journal, status: .idle).now.attempts

    #expect(Set(attempts.map(\.cardID)) == ["C-1", "C-2"])
    #expect(attempts.first { $0.cardID == "C-1" }?.repo == "app")
    #expect(attempts.first { $0.cardID == "C-2" }?.repo == "api")
    #expect(attempts.allSatisfy { $0.round == 1 })
}

@Test("Feature lanes count done/total and rank landed > blocked > waiting on you > running")
func featureLanes() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let feature = try insertFeature(journal, issueID: "F-1")
    let cycle = feature.cycleID
    try insertCard(journal, cycleID: cycle, issueID: "A-1", repository: "a", state: .done, order: 1)
    try insertCard(
        journal, cycleID: cycle, issueID: "A-2",
        repository: "a", state: .blocked, blockReason: .hardFailure, order: 2
    )
    try insertCard(
        journal, cycleID: cycle, issueID: "B-1",
        repository: "b", state: .blocked, blockReason: .hardFailure, order: 1
    )
    try insertCard(journal, cycleID: cycle, issueID: "B-2", repository: "b", state: .waitingOnYou, order: 2)
    try insertCard(journal, cycleID: cycle, issueID: "C-1", repository: "c", state: .waitingOnYou, order: 1)
    try insertCard(journal, cycleID: cycle, issueID: "C-2", repository: "c", state: .todo, order: 2)
    try insertCard(journal, cycleID: cycle, issueID: "D-1", repository: "d", state: .inProgress, order: 1)
    try insertCard(journal, cycleID: cycle, issueID: "D-2", repository: "d", state: .done, order: 2)
    try insertCard(journal, cycleID: cycle, issueID: "D-3", repository: "d", state: .cancelled, order: 3)
    _ = try journal.recordLanding(featureID: feature.featureID, repository: "a", mainlineCommit: "abc", now: epoch)
    let run = RunID()
    _ = try journal.claimActLease(act: .land, runID: run, mode: .real, now: epoch)
    let opening = try journal.openNight(nightStart: nightStart, mode: .real, act: .land, runID: run, now: epoch)
    _ = try journal.recordPullRequest(
        featureID: feature.featureID, repository: "a", url: "https://github.com/o/r/pull/42",
        nightID: opening.night.id, runID: run, now: epoch
    )
    _ = try journal.recordPullRequest(
        featureID: feature.featureID, repository: "b", url: nil,
        nightID: opening.night.id, runID: run, now: epoch
    )

    let snapshot = try #require(try PulseSnapshot.read(from: journal, status: .idle).feature)
    let lanes = Dictionary(uniqueKeysWithValues: snapshot.lanes.map { ($0.repo, $0) })

    #expect(snapshot.id == "F-1")
    #expect(snapshot.title == nil)
    #expect(snapshot.state == nil)
    #expect(snapshot.rollupState == nil)
    #expect(lanes["a"]?.state == .landed)
    #expect(lanes["b"]?.state == .blocked)
    #expect(lanes["c"]?.state == .waitingOnYou)
    #expect(lanes["d"]?.state == .running)
    #expect(lanes["a"]?.cardsDone == 1)
    #expect(lanes["a"]?.cardsTotal == 2)
    #expect(lanes["d"]?.cardsDone == 1)
    #expect(lanes["d"]?.cardsTotal == 2)  // the Cancelled Card is out of the lane
    #expect(lanes["a"]?.pullRequest == PullRequestChip(number: 42, state: nil))
    #expect(lanes["b"]?.pullRequest == nil)
    #expect(lanes["a"]?.cards.map(\.id) == ["A-1", "A-2"])
    #expect(lanes["d"]?.cards.map(\.id) == ["D-1", "D-2"])  // the Cancelled Card is not a member
    #expect(lanes["c"]?.pullRequest == nil)
}

@Test("An opened Night reads as running, a closed one as done")
func nightState() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()
    _ = try journal.claimActLease(act: .author, runID: run, mode: .real, now: epoch)
    let opening = try journal.openNight(nightStart: nightStart, mode: .real, act: .author, runID: run, now: epoch)

    let running = try #require(try PulseSnapshot.read(from: journal, status: .idle).night)
    #expect(running.state == .running)
    #expect(running.startedAt == epoch)
    #expect(running.verdictLine == nil)

    _ = try journal.closeNight(
        id: opening.night.id, reason: .nightEnd, act: .author, runID: run, now: epoch.addingTimeInterval(10)
    )
    let done = try #require(try PulseSnapshot.read(from: journal, status: .idle).night)
    #expect(done.state == .done)
}

@Test("Dispositions count the Cards touched this Night by state, zero counts omitted")
func nightDispositions() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let feature = try insertFeature(journal, issueID: "F-1")
    let done = try insertCard(journal, cycleID: feature.cycleID, issueID: "C-1", state: .done, order: 1)
    let blocked = try insertCard(
        journal, cycleID: feature.cycleID, issueID: "C-2", state: .blocked, blockReason: .hardFailure, order: 2
    )
    try insertCard(journal, cycleID: feature.cycleID, issueID: "C-3", state: .todo, order: 3)
    let run = RunID()
    _ = try journal.claimActLease(act: .build, runID: run, mode: .real, now: epoch)
    let opening = try journal.openNight(nightStart: nightStart, mode: .real, act: .build, runID: run, now: epoch)
    for (cardID, issueID) in [(done, "C-1"), (blocked, "C-2")] {
        try journal.append(
            .cardRunStep(cardID: cardID, issueID: issueID, step: .leaseClaimed, detail: nil),
            act: .build, runID: run, nightID: opening.night.id, now: epoch
        )
    }

    let night = try #require(try PulseSnapshot.read(from: journal, status: .idle).night)

    #expect(night.cardsByDisposition == [
        DispositionCount(disposition: .done, count: 1),
        DispositionCount(disposition: .blocked, count: 1)
    ])
}

@Test("Two Journals read separately, each reflecting only its own data")
func twoJournalsStaySeparate() throws {
    let first = try JournalFixture(project: "alpha")
    let second = try JournalFixture(project: "beta")
    let alpha = try first.open()
    let beta = try second.open()
    let alphaFeature = try insertFeature(alpha, issueID: "ALPHA-F")
    try insertCard(
        alpha, cycleID: alphaFeature.cycleID, issueID: "ALPHA-1",
        repository: "a", state: .blocked, blockReason: .hardFailure
    )
    let betaFeature = try insertFeature(beta, issueID: "BETA-F")
    try insertCard(beta, cycleID: betaFeature.cycleID, issueID: "BETA-1", repository: "b", state: .waitingOnYou)
    let run = RunID()
    _ = try beta.claimActLease(act: .author, runID: run, mode: .real, now: epoch)
    _ = try beta.openNight(nightStart: nightStart, mode: .real, act: .author, runID: run, now: epoch)

    let alphaPulse = try PulseSnapshot.read(from: alpha, status: .idle)
    let betaPulse = try PulseSnapshot.read(from: beta, status: .working)

    #expect(alphaPulse.needsYou.cards.map(\.id) == ["ALPHA-1"])
    #expect(alphaPulse.feature?.id == "ALPHA-F")
    #expect(alphaPulse.feature?.lanes.map(\.repo) == ["a"])
    #expect(alphaPulse.night == nil)
    #expect(alphaPulse.now.status == .idle)
    #expect(betaPulse.needsYou.cards.map(\.id) == ["BETA-1"])
    #expect(betaPulse.feature?.id == "BETA-F")
    #expect(betaPulse.feature?.lanes.map(\.repo) == ["b"])
    #expect(betaPulse.night?.state == .running)
    #expect(betaPulse.now.status == .working)
}

@Test("A touched repository with a No-Pushed-Branch Outcome is still listed as a lane, and is not landed")
func noPushedBranchRepositoryStaysAListedLane() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let feature = try insertFeature(journal, issueID: "F-1")
    try insertCard(journal, cycleID: feature.cycleID, issueID: "A-1", repository: "a", state: .done, order: 1)
    try journal.write { db in
        try JournalStore.insertFeatureRepositories(db, featureID: feature.featureID, repositories: ["a", "web"])
    }
    try journal.append(.noPushedBranchOutcome(cycleID: feature.cycleID, featureIssueID: "F-1", repository: "web"))
    _ = try journal.recordLanding(featureID: feature.featureID, repository: "a", mainlineCommit: "abc", now: epoch)

    let snapshot = try #require(try PulseSnapshot.read(from: journal, status: .idle).feature)
    let lanes = Dictionary(uniqueKeysWithValues: snapshot.lanes.map { ($0.repo, $0) })

    #expect(Set(lanes.keys) == ["a", "web"])
    #expect(lanes["a"]?.state == .landed)
    #expect(lanes["web"]?.state != .landed)
}
