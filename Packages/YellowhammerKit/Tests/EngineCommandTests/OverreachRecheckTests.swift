import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
import Journal
import Repositories
import Testing

// roadmap P8.3: re-checking Work Cards Waiting on You under overreach on every build Act
// (bounds/refuse-protected-paths-before-dispatch). Fixture helpers are shared with
// ReadinessCheckTests.swift and ProtectedPathsRefusalTests.swift.

@Test("A Work Card whose scope clears is dispatched on that build Act, followed by held sequence cards")
func scopeClearsDispatchesInOrder() async throws {
    let scenario = try await makeReadinessScenario()
    defer { cleanup(scenario) }
    try makeReadyCardOne(scenario)
    try scenario.journal.recordDeclaredScope(cardID: scenario.cardOne, paths: ["Sources/App/", "Secrets/keys.env"])

    // Act 1: refused under overreach.
    try await runReadinessAct(scenario, readiness: makeReadinessCheck(), repositories: protectedRepositories)

    let cardAfterAct1 = try #require(try scenario.journal.card(issueID: scenario.issueOne))
    #expect(cardAfterAct1.state == .waitingOnYou)
    #expect(cardAfterAct1.waitingReason == .overreach)
    #expect(scenario.recorder.seen.isEmpty)
    #expect(try scenario.journal.attemptHistory(cardID: scenario.cardOne).attempts.isEmpty)

    // Edit scope between Acts to clear protected path overlap.
    try scenario.journal.recordDeclaredScope(cardID: scenario.cardOne, paths: ["Sources/App/"])

    // Act 2: recheck clears overreach, transitions to Todo, dispatches card one then card two.
    try await runReadinessAct(
        scenario, readiness: makeReadinessCheck(), trigger: .forced, repositories: protectedRepositories
    )

    #expect(scenario.recorder.seen.map(\.issueID) == [scenario.issueOne, scenario.issueTwo])
    let leftWaiting = try scenario.journal.events(ofType: .cardStateTransitioned).contains {
        if case .cardStateTransitioned(let cardID, _, .waitingOnYou, .todo, _, _) = $0.event {
            return cardID == scenario.cardOne
        }
        return false
    }
    #expect(leftWaiting)
    let cardOneDone = try #require(try scenario.journal.card(issueID: scenario.issueOne))
    let cardTwoDone = try #require(try scenario.journal.card(issueID: scenario.issueTwo))
    #expect(cardOneDone.state == .done)
    #expect(cardTwoDone.state == .done)
}

@Test("A Work Card whose configuration clears is dispatched on that build Act")
func configurationClearsDispatchesInOrder() async throws {
    let scenario = try await makeReadinessScenario()
    defer { cleanup(scenario) }
    try makeReadyCardOne(scenario)
    try scenario.journal.recordDeclaredScope(cardID: scenario.cardOne, paths: ["Sources/App/", "Secrets/keys.env"])

    // Act 1: refused under overreach.
    try await runReadinessAct(scenario, readiness: makeReadinessCheck(), repositories: protectedRepositories)

    #expect(try scenario.journal.card(issueID: scenario.issueOne)?.state == .waitingOnYou)
    #expect(scenario.recorder.seen.isEmpty)

    // Act 2: repositories configured without protected paths; card one clears and dispatches.
    try await runReadinessAct(
        scenario, readiness: makeReadinessCheck(), trigger: .forced, repositories: readinessRepositories
    )

    #expect(scenario.recorder.seen.map(\.issueID) == [scenario.issueOne, scenario.issueTwo])
    #expect(try scenario.journal.card(issueID: scenario.issueOne)?.state == .done)
}

@Test("Still overlapping with changed overlap set records new refusal and posts new comment without restarting clock")
func stillOverlappingSetChangedPostsCommentAndDoesNotResetClock() async throws {
    let scenario = try await makeReadinessScenario()
    defer { cleanup(scenario) }
    try makeReadyCardOne(scenario)
    try scenario.journal.recordDeclaredScope(cardID: scenario.cardOne, paths: ["Secrets/old.env"])

    // Act 1: refused under overreach.
    try await runReadinessAct(scenario, readiness: makeReadinessCheck(), repositories: protectedRepositories)

    let refusedAct1 = try scenario.journal.events(ofType: .protectedPathRefused)
    #expect(refusedAct1.count == 1)
    let commentsAct1 = await scenario.boards.writing.comments.filter { $0.issue.rawValue == scenario.issueOne }
    #expect(commentsAct1.count == 1)

    // Seed unanswered_nights to 2 and update scope to a different protected path.
    try scenario.journal.write { database in
        try database.execute(sql: "UPDATE card SET unanswered_nights = 2 WHERE id = ?", arguments: [scenario.cardOne])
    }
    try scenario.journal.recordDeclaredScope(cardID: scenario.cardOne, paths: ["Secrets/new.env"])

    // Act 2: still overlaps, overlap set changed.
    try await runReadinessAct(
        scenario, readiness: makeReadinessCheck(), trigger: .forced, repositories: protectedRepositories
    )

    let refusedAct2 = try scenario.journal.events(ofType: .protectedPathRefused)
    #expect(refusedAct2.count == 2)
    guard case .protectedPathRefused(_, _, _, let declared, _) = refusedAct2.last?.event else {
        Issue.record("expected protectedPathRefused event")
        return
    }
    #expect(declared == "Secrets/new.env")

    let commentsAct2 = await scenario.boards.writing.comments.filter { $0.issue.rawValue == scenario.issueOne }
    #expect(commentsAct2.count == 2)
    #expect(commentsAct2.last?.body.contains("Secrets/new.env") == true)

    let card = try #require(try scenario.journal.card(issueID: scenario.issueOne))
    #expect(card.state == .waitingOnYou)
    #expect(card.waitingReason == .overreach)
    #expect(card.unansweredNights == 2)
    #expect(scenario.recorder.seen.isEmpty)
}

@Test("Still overlapping with unchanged overlap set writes nothing")
func stillOverlappingSetUnchangedWritesNothing() async throws {
    let scenario = try await makeReadinessScenario()
    defer { cleanup(scenario) }
    try makeReadyCardOne(scenario)
    try scenario.journal.recordDeclaredScope(cardID: scenario.cardOne, paths: ["Secrets/keys.env"])

    // Act 1: refused under overreach.
    try await runReadinessAct(scenario, readiness: makeReadinessCheck(), repositories: protectedRepositories)

    let refusedAct1 = try scenario.journal.events(ofType: .protectedPathRefused)
    #expect(refusedAct1.count == 1)
    let commentsAct1 = await scenario.boards.writing.comments.filter { $0.issue.rawValue == scenario.issueOne }
    #expect(commentsAct1.count == 1)

    // Act 2: still overlaps, overlap set unchanged.
    try await runReadinessAct(
        scenario, readiness: makeReadinessCheck(), trigger: .forced, repositories: protectedRepositories
    )

    let refusedAct2 = try scenario.journal.events(ofType: .protectedPathRefused)
    #expect(refusedAct2.count == 1)
    let commentsAct2 = await scenario.boards.writing.comments.filter { $0.issue.rawValue == scenario.issueOne }
    #expect(commentsAct2.count == 1)

    let card = try #require(try scenario.journal.card(issueID: scenario.issueOne))
    #expect(card.state == .waitingOnYou)
    #expect(card.waitingReason == .overreach)
    #expect(scenario.recorder.seen.isEmpty)
}

@Test("Still overlapping with stale transcription block diverges")
func stillOverlappingPlusStaleBlockDiverges() async throws {
    let scenario = try await makeReadinessScenario()
    defer { cleanup(scenario) }
    try makeReadyCardOne(scenario)
    try scenario.journal.recordDeclaredScope(cardID: scenario.cardOne, paths: ["Secrets/keys.env"])
    try scenario.journal.recordTranscriptionBlocks(cardID: scenario.cardOne, [
        TranscriptionBlock(
            repository: "backend", paths: ["a.swift"], mainlineCommit: "deadbeef", content: "old",
            contentHash: ManagedBlockFence.sha256("old"), authorSupplied: false
        )
    ])

    // Act 1: refused under overreach (clean provenance).
    try await runReadinessAct(scenario, readiness: makeReadinessCheck(), repositories: protectedRepositories)
    #expect(try scenario.journal.card(id: scenario.cardOne).waitingReason == .overreach)

    // Act 2: provenance becomes stale; divergence wins.
    let staleReadiness = ReadinessCheck(
        provenance: FakeProvenanceTester(verdicts: ["backend": .stale(changedPaths: ["a.swift"])]),
        citations: FakeCitationResolver(resolvable: ["resolvable/story"])
    )
    try await runReadinessAct(
        scenario, readiness: staleReadiness, trigger: .forced, repositories: protectedRepositories
    )

    let card = try #require(try scenario.journal.card(issueID: scenario.issueOne))
    #expect(card.state == .waitingOnYou)
    #expect(card.waitingReason == .divergence)

    let comments = await scenario.boards.writing.comments.filter { $0.issue.rawValue == scenario.issueOne }
    #expect(comments.contains { $0.body.contains("has diverged") })
    #expect(scenario.recorder.seen.isEmpty)
}

@Test("A reply on an overreach card with no scope edit leaves it in Waiting on You and gets acknowledgement (b)")
func replyWithNoEditLeavesWaitingAndGetsAcknowledgement() async throws {
    let scenario = try await makeReadinessScenario()
    defer { cleanup(scenario) }
    try makeReadyCardOne(scenario)
    try scenario.journal.recordDeclaredScope(cardID: scenario.cardOne, paths: ["Secrets/keys.env"])

    // Act 1: refused under overreach.
    try await runReadinessAct(scenario, readiness: makeReadinessCheck(), repositories: protectedRepositories)

    // Act 2: a human reply arrives with no Scope edit.
    let reply = comment("reply-1", on: scenario.issueOne, author: humanAuthor, createdAt: 1_000)
    try await runReadinessAct(
        scenario, readiness: makeReadinessCheck(), comments: [reply], trigger: .forced,
        repositories: protectedRepositories
    )

    let card = try #require(try scenario.journal.card(issueID: scenario.issueOne))
    #expect(card.state == .waitingOnYou)
    #expect(card.waitingReason == .overreach)

    let acks = await scenario.boards.writing.comments.filter { $0.body.hasPrefix("**Nothing changed;") }
    #expect(acks.count == 1)
    #expect(acks[0].body.contains("Secrets/keys.env"))
    #expect(scenario.recorder.seen.isEmpty)
}

@Test("A Waiting on You card whose overdue nights run out is auto-Blocked decision overdue and not dispatched")
func overdueExpiryAutoBlocksDecisionOverdueAndIsNotDispatched() async throws {
    let scenario = try await makeReadinessScenario()
    defer { cleanup(scenario) }
    try makeReadyCardOne(scenario)
    try scenario.journal.recordDeclaredScope(cardID: scenario.cardOne, paths: ["Secrets/keys.env"])

    // Act 1: refused under overreach.
    try await runReadinessAct(scenario, readiness: makeReadinessCheck(), repositories: protectedRepositories)

    // Advance unanswered_nights to the bound (3).
    try scenario.journal.write { database in
        try database.execute(sql: "UPDATE card SET unanswered_nights = 3 WHERE id = ?", arguments: [scenario.cardOne])
    }

    // Act 2: next night advances clock past bound; auto-blocks decision overdue.
    let nextNight = try #require(NightStart(rawValue: "2026-09-18"))
    try await runReadinessAct(
        scenario, readiness: makeReadinessCheck(), nightStart: nextNight, trigger: .forced,
        repositories: protectedRepositories
    )

    let card = try #require(try scenario.journal.card(issueID: scenario.issueOne))
    #expect(card.state == .blocked)
    #expect(card.blockReason == BlockReason.decisionOverdue.rawValue)

    #expect(scenario.recorder.seen.isEmpty)
    let cardTwo = try #require(try scenario.journal.card(issueID: scenario.issueTwo))
    #expect(cardTwo.state == .todo)
}
