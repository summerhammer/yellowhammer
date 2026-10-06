import Domain
import Foundation
import Testing

@testable import Journal
@testable import Pulse

// The Inspector's Card detail (roadmap P18.8, carrying P14.5's account behind a Card): read read-only
// from the Card's own Project's Journal, found by that Project's id alone.

/// A throwaway configuration directory holding only Journals. Removed on deinit, so a test creates it in
/// its own body.
private struct JournalsFixture: ~Copyable {
    let directory: URL

    init() {
        directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-card-detail-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func project(_ id: String) throws -> ProjectID {
        try #require(ProjectID(rawValue: id))
    }

    func openJournal(_ id: String) throws -> JournalStore {
        try JournalStore.open(configurationDirectory: directory, projectID: try project(id))
    }

    func journalURL(_ id: String) throws -> URL {
        JournalStore.defaultFileURL(configurationDirectory: directory, id: try project(id))
    }

    func read(_ issueID: String, in id: String) throws -> CardDetailRead {
        CardDetail.read(issueID: issueID, project: try project(id), configurationDirectory: directory)
    }
}

private func otherRoute() throws -> Route {
    try #require(Route(cli: "codex", model: "gpt-5", effort: "high"))
}

/// ALPHA-1, Blocked by its Check: a first Attempt whose Check Round failed and whose route was then
/// excluded, and a second Attempt with a review Round asking for changes and two Check runs. ALPHA-2 has
/// a Check run of its own, which must not appear in ALPHA-1's detail.
private func seedTwoAttempts(_ journal: JournalStore) throws {
    let feature = try insertFeature(journal, issueID: "ALPHA-F")
    let card = try insertCard(
        journal, cycleID: feature.cycleID, issueID: "ALPHA-1",
        repository: "backend", state: .blocked, blockReason: .checkFailure
    )
    let other = try insertCard(journal, cycleID: feature.cycleID, issueID: "ALPHA-2", repository: "backend", order: 2)
    let run = RunID()
    _ = try journal.claimActLease(act: .build, runID: run, mode: .real, now: epoch)

    let first = try journal.recordAttempt(cardID: card, route: route(), routeSource: "entry", runID: run, now: epoch)
    _ = try journal.recordRound(
        attemptID: first.id, lens: .check, verdict: "failed", requestedChanges: "build failed",
        judgedCommit: "abc123", runID: run, now: epoch.addingTimeInterval(10)
    )
    try journal.append(
        .checkRan(
            cardID: card, issueID: "ALPHA-1", attemptID: first.id, result: .failed,
            exitStatus: 1, output: "build failed: line 42"
        ),
        runID: run, now: epoch.addingTimeInterval(11)
    )
    _ = try journal.endAttempt(
        attemptID: first.id, result: "hardFailure", classification: "capability", consumedHow: "route failed",
        runID: run, now: epoch.addingTimeInterval(20)
    )
    try journal.write { db in
        try db.execute(
            sql: """
            INSERT INTO route_exclusion
            (card_id, budget_epoch, route_cli, route_model, route_effort, reason, excluded_at)
            VALUES (?, 0, 'claude', 'sonnet', 'medium', 'capability', ?)
            """,
            arguments: [card, JournalStore.timestamp(epoch.addingTimeInterval(20))]
        )
    }

    try seedSecondAttempt(journal, cardID: card, runID: run)
    try seedOtherCheckRun(journal, cardID: other, runID: run)
    _ = try journal.releaseActLease(runID: run)
}

/// ALPHA-1's second Attempt, on the other route: a review Round asking for changes, a passed Check run
/// and a declared-none one. It has not ended.
private func seedSecondAttempt(_ journal: JournalStore, cardID card: Int64, runID run: RunID) throws {
    let second = try journal.recordAttempt(
        cardID: card, route: otherRoute(), routeSource: "fallback:1", runID: run, now: epoch.addingTimeInterval(30)
    )
    _ = try journal.recordRound(
        attemptID: second.id, lens: .review, verdict: "changes requested", requestedChanges: "rename the type",
        judgedCommit: "def456", runID: run, now: epoch.addingTimeInterval(40)
    )
    try journal.append(
        .checkRan(
            cardID: card, issueID: "ALPHA-1", attemptID: second.id, result: .passed, exitStatus: 0, output: nil
        ),
        runID: run, now: epoch.addingTimeInterval(41)
    )
    try journal.append(
        .checkRan(
            cardID: card, issueID: "ALPHA-1", attemptID: second.id, result: .declaredNone, exitStatus: nil, output: nil
        ),
        runID: run, now: epoch.addingTimeInterval(42)
    )
}

/// ALPHA-2's own Attempt and Check run, under the Act Lease `runID` holds.
private func seedOtherCheckRun(_ journal: JournalStore, cardID: Int64, runID: RunID) throws {
    let attempt = try journal.recordAttempt(cardID: cardID, route: route(), runID: runID, now: epoch)
    try journal.append(
        .checkRan(
            cardID: cardID, issueID: "ALPHA-2", attemptID: attempt.id, result: .passed, exitStatus: 0, output: nil
        ),
        runID: runID, now: epoch.addingTimeInterval(50)
    )
}

@Test("Card detail carries the Card, its routes and every Attempt with its Rounds and Check runs, oldest first")
func cardDetailCarriesTheAccount() throws {
    let fixture = JournalsFixture()
    do { try seedTwoAttempts(try fixture.openJournal("alpha")) }

    guard case let .detail(detail) = try fixture.read("ALPHA-1", in: "alpha") else {
        Issue.record("ALPHA-1 was not read")
        return
    }

    #expect(detail.id == "ALPHA-1")
    #expect(detail.title == "ALPHA-1")
    #expect(detail.repo == "backend")
    #expect(detail.kind == "card")
    #expect(detail.state == .blocked)
    #expect(detail.blockReason == .checkFailure)
    #expect(detail.waitingReason == nil)
    #expect(detail.budgetEpoch == 0)
    #expect(detail.routesTried == ["claude/sonnet/medium", "codex/gpt-5/high"])
    #expect(detail.excludedRoutes == ["claude/sonnet/medium"])
    #expect(detail.attemptCount == 2)
    #expect(detail.roundCount == 2)

    let first = detail.attempts[0]
    #expect(first.route == "claude/sonnet/medium")
    #expect(first.routeSource == "entry")
    #expect(first.endedAt == epoch.addingTimeInterval(20))
    #expect(first.result == "hardFailure")
    #expect(first.classification == "capability")
    #expect(first.consumedHow == "route failed")
    #expect(first.rounds.map(\.lens) == [.check])
    #expect(first.rounds.first?.judgedCommit == "abc123")
    #expect(first.checkRuns.map(\.result) == [.failed])
    #expect(first.checkRuns.first?.exitStatus == 1)
    #expect(first.checkRuns.first?.output == "build failed: line 42")

    let second = detail.attempts[1]
    #expect(second.routeSource == "fallback:1")
    #expect(second.endedAt == nil)
    #expect(second.result == nil)
    #expect(second.rounds.map(\.requestedChanges) == ["rename the type"])
    #expect(second.checkRuns.map(\.result) == [.passed, .declaredNone])
}

@Test("A Card's detail is read from its own Project's Journal alone")
func cardDetailReadsItsOwnJournal() throws {
    let fixture = JournalsFixture()
    do {
        let alpha = try fixture.openJournal("alpha")
        let alphaFeature = try insertFeature(alpha, issueID: "ALPHA-F")
        try insertCard(
            alpha, cycleID: alphaFeature.cycleID, issueID: "SHARED-1", repository: "backend", state: .blocked
        )

        let beta = try fixture.openJournal("beta")
        let betaFeature = try insertFeature(beta, issueID: "BETA-F")
        let shared = try insertCard(
            beta, cycleID: betaFeature.cycleID, issueID: "SHARED-1", repository: "web", state: .waitingOnYou
        )
        try insertCard(beta, cycleID: betaFeature.cycleID, issueID: "BETA-2", repository: "web", order: 2)
        let run = RunID()
        _ = try beta.claimActLease(act: .build, runID: run, mode: .real, now: epoch)
        _ = try beta.recordAttempt(cardID: shared, route: otherRoute(), runID: run, now: epoch)
        _ = try beta.releaseActLease(runID: run)
    }

    guard
        case let .detail(alpha) = try fixture.read("SHARED-1", in: "alpha"),
        case let .detail(beta) = try fixture.read("SHARED-1", in: "beta")
    else {
        Issue.record("SHARED-1 was not read from both Journals")
        return
    }

    #expect(alpha.repo == "backend")
    #expect(alpha.state == .blocked)
    #expect(alpha.attempts.isEmpty)
    #expect(beta.repo == "web")
    #expect(beta.state == .waitingOnYou)
    #expect(beta.routesTried == ["codex/gpt-5/high"])
    #expect(try fixture.read("BETA-2", in: "alpha") == .noSuchCard)
}

@Test("Waiting on You carries its waiting_reason and no Block Reason; a reason outside its state is dropped")
func cardDetailReasonsFollowTheState() throws {
    let fixture = JournalsFixture()
    do {
        let journal = try fixture.openJournal("alpha")
        let feature = try insertFeature(journal, issueID: "ALPHA-F")
        let card = try insertCard(journal, cycleID: feature.cycleID, issueID: "ALPHA-1", state: .inProgress)
        let run = RunID()
        _ = try journal.claimActLease(act: .build, runID: run, mode: .real, now: epoch)
        _ = try journal.transitionCard(
            cardID: card, to: .waitingOnYou, waitingReason: .divergence,
            runID: run, act: .build, nightID: nil, now: epoch
        )
        _ = try journal.releaseActLease(runID: run)
        // A Block Reason left on a Card that is not Blocked says nothing about it.
        try insertCard(
            journal, cycleID: feature.cycleID, issueID: "ALPHA-2",
            state: .todo, blockReason: .routeFailure, order: 2
        )
    }

    guard
        case let .detail(waiting) = try fixture.read("ALPHA-1", in: "alpha"),
        case let .detail(todo) = try fixture.read("ALPHA-2", in: "alpha")
    else {
        Issue.record("The Cards were not read")
        return
    }

    #expect(waiting.state == .waitingOnYou)
    #expect(waiting.waitingReason == "divergence")
    #expect(waiting.blockReason == nil)
    #expect(todo.blockReason == nil)
}

@Test("Waiting on You with overreach carries its waiting_reason and no Block Reason")
func cardDetailOverreachWaitingReason() throws {
    let fixture = JournalsFixture()
    do {
        let journal = try fixture.openJournal("alpha")
        let feature = try insertFeature(journal, issueID: "ALPHA-F")
        let card = try insertCard(journal, cycleID: feature.cycleID, issueID: "ALPHA-1", state: .inProgress)
        let run = RunID()
        _ = try journal.claimActLease(act: .build, runID: run, mode: .real, now: epoch)
        _ = try journal.transitionCard(
            cardID: card, to: .waitingOnYou, waitingReason: .overreach,
            runID: run, act: .build, nightID: nil, now: epoch
        )
        _ = try journal.releaseActLease(runID: run)
    }

    guard case let .detail(waiting) = try fixture.read("ALPHA-1", in: "alpha") else {
        Issue.record("The Card was not read")
        return
    }

    #expect(waiting.state == .waitingOnYou)
    #expect(waiting.waitingReason == "overreach")
    #expect(waiting.blockReason == nil)
}

@Test("A Project with no Journal reads as journalMissing, and no Journal is created")
func cardDetailMissingJournal() throws {
    let fixture = JournalsFixture()

    #expect(try fixture.read("ALPHA-1", in: "alpha") == .journalMissing)
    #expect(!FileManager.default.fileExists(atPath: try fixture.journalURL("alpha").path))
}

@Test("An unreadable Journal reads as a journalFailure in the Journal's own words")
func cardDetailUnreadableJournal() throws {
    let fixture = JournalsFixture()
    let url = try fixture.journalURL("alpha")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("not a database".utf8).write(to: url)

    guard case let .journalFailure(message) = try fixture.read("ALPHA-1", in: "alpha") else {
        Issue.record("An unreadable Journal was not a failure")
        return
    }
    #expect(!message.isEmpty)
}

@Test("Reading a Card's detail leaves its Journal byte-for-byte unchanged and adds no sibling file")
func cardDetailReadDoesNotModifyTheJournal() throws {
    let fixture = JournalsFixture()
    do { try seedTwoAttempts(try fixture.openJournal("alpha")) }
    let url = try fixture.journalURL("alpha")
    let directory = url.deletingLastPathComponent()
    let before = try Data(contentsOf: url)
    let siblingsBefore = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))

    for _ in 0..<5 {
        _ = try fixture.read("ALPHA-1", in: "alpha")
    }

    #expect(try Data(contentsOf: url) == before)
    #expect(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)) == siblingsBefore)
}
