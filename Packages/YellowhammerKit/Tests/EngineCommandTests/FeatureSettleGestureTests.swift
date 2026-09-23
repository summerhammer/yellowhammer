import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
import GRDB
@testable import Journal
import Repositories
import Testing

// roadmap P10.9 (spec: morning-report/triage-the-morning): the Operator's settle gesture, a tri-state
// read of the Feature Issue's workflow state — unsettled, kept in flight, released. Never asserts
// anything model-authored.

@Suite("Settle a Feature (P10.9)")
struct FeatureSettleGestureTests {
    @Test("kept in flight: stays in flight, triages the previous Night, no Card or board writes")
    func keptInFlightStaysInFlight() async throws {
        let world = try await makeSettleWorld()
        await world.seedFeatureIssueState(SettleValue.keptInFlight.rawValue)
        let context = try world.makeContext()
        let updatesBefore = await world.boards.writing.updateCalls
        let gesture = FeatureSettleGesture()

        try await gesture.settle(feature: try inFlightFeature(world), cycleID: world.cycleID, context: context)

        #expect(try world.journal.inFlightFeature() != nil)
        #expect(try settleNightTriagedAt(world.journal, nightID: world.previousNightID) != nil)
        #expect(try settleNightTriagedAt(world.journal, nightID: context.night.id) == nil)

        let events = try world.journal.events(ofType: .featureSettled)
        #expect(events.count == 1)
        guard case .featureSettled(let cycleID, let featureIssueID, let accepted, let triagedNightID) = events[0].event
        else {
            Issue.record("expected featureSettled")
            return
        }
        #expect(cycleID == world.cycleID)
        #expect(featureIssueID == "FEAT-1")
        #expect(accepted == ["BACK-1"])
        #expect(triagedNightID == world.previousNightID)

        // No Card or board state write: every Card is exactly as seeded.
        #expect(try world.journal.card(id: world.waitingCardID).state == .waitingOnYou)
        #expect(try world.journal.card(id: world.blockedCardID).state == .blocked)
        #expect(await world.boards.writing.updateCalls == updatesBefore)
        #expect(await world.boards.writing.createCommentCalls == 0)

        let line = NightCardMaintenance.authoringLine(for: events[0].event)
        #expect(line?.contains("kept in flight") == true)
    }

    @Test("kept in flight twice in the same Night appends nothing further")
    func keptInFlightSameNightIsIdempotent() async throws {
        let world = try await makeSettleWorld()
        await world.seedFeatureIssueState(SettleValue.keptInFlight.rawValue)
        let context = try world.makeContext()
        let gesture = FeatureSettleGesture()

        try await gesture.settle(feature: try inFlightFeature(world), cycleID: world.cycleID, context: context)
        try await gesture.settle(feature: try inFlightFeature(world), cycleID: world.cycleID, context: context)

        #expect(try world.journal.events(ofType: .featureSettled).count == 1)
    }

    @Test("released on a running Feature: salvages, archives the Cycle, never archives the Feature Issue")
    func releasedOnARunningFeature() async throws {
        let world = try await makeSettleWorld()
        let active = try await world.seedActiveCards()
        try world.holdWorktree(repository: "backend", pushed: true)
        try world.holdWorktree(repository: "mobile", pushed: false)
        try world.journal.recordPullRequest(
            featureID: world.featureID, repository: "backend", url: "https://github.com/acme/backend/pull/1",
            nightID: world.previousNightID, runID: RunID()
        )
        await world.seedFeatureIssueState(SettleValue.released.rawValue)
        let context = try world.makeContext()
        let feature = try inFlightFeature(world)

        try await FeatureSettleGesture().settle(feature: feature, cycleID: world.cycleID, context: context)

        // The Waiting on You Card was auto-Blocked unanswered, its counters untouched.
        let waiting = try world.journal.card(id: world.waitingCardID)
        #expect(waiting.state == .blocked)
        #expect(waiting.blockReason == BlockReason.unanswered.rawValue)
        #expect(waiting.budgetEpoch == 2)

        // Both Blocked Cards are detached; Done and Cancelled are untouched.
        let waitingIssue = try #require(await world.boards.writing.issue(BoardObjectID(rawValue: "MOB-1")))
        #expect(waitingIssue.parent == nil)
        let blockedIssue = try #require(await world.boards.writing.issue(BoardObjectID(rawValue: "BACK-2")))
        #expect(blockedIssue.parent == nil)
        let doneIssue = try #require(await world.boards.writing.issue(BoardObjectID(rawValue: "BACK-1")))
        #expect(doneIssue.parent == BoardObjectID(rawValue: "FEAT-1"))

        // Every held Worktree is released, pushed or not.
        #expect(world.workspace.removeCalls.count == 2)
        let worktrees = try world.journal.worktrees(featureID: world.featureID)
        #expect(worktrees.allSatisfy { !$0.isHeld })

        // The Cycle is archived, never with closed_by; the Feature is released, not closed.
        let row = try settleFeatureRow(world.journal, featureID: world.featureID)
        #expect(row.releasedAt != nil)
        #expect(row.closedBy == nil)
        #expect(try world.journal.inFlightCycleID() == nil)

        // The Feature Issue itself is never archived.
        let featureIssue = try #require(await world.boards.writing.issue(BoardObjectID(rawValue: "FEAT-1")))
        #expect(!featureIssue.archived)

        // Exactly one narrative comment, naming the abandoned pull request and never claiming a landing.
        #expect(await world.boards.writing.createCommentCalls == 1)
        let featureIssueID = BoardObjectID(rawValue: "FEAT-1")
        let comment = try #require(await world.boards.writing.comments.first { $0.issue == featureIssueID })
        #expect(comment.body.hasPrefix("**Released.**"))
        #expect(comment.body.contains("backend"))
        #expect(!comment.body.localizedCaseInsensitiveContains("landed this"))

        // No landing was recorded by this release.
        #expect(try world.journal.landings(featureID: world.featureID).isEmpty)

        let events = try world.journal.events(ofType: .featureReleased)
        #expect(events.count == 1)
        guard case .featureReleased(_, _, let carried, let accepted, let abandoned, _) = events[0].event else {
            Issue.record("expected featureReleased")
            return
        }
        #expect(carried == ["BACK-2", "BACK-3", "MOB-1", "MOB-3"])
        #expect(accepted == ["BACK-1"])
        #expect(abandoned == ["backend"])
        try await assertReleasedActiveCards(world, active: active, comment: comment.body)

        // The same author Act proceeds past the predecessor gate: the walk skips a released Feature.
        let walk = try world.journal.predecessorFeature()
        #expect(walk.predecessor == nil)
    }

    @Test("A live Card Lease prevents release until its holder lets go")
    func releasedActiveCardHeldByAnotherRun() async throws {
        let world = try await makeSettleWorld()
        let active = try await world.seedActiveCards()
        await world.seedFeatureIssueState(SettleValue.released.rawValue)
        let context = try world.makeContext()
        let holder = RunID()
        _ = try world.journal.claimCardLease(cardID: active.todo, runID: holder)
        let gesture = FeatureSettleGesture()

        await #expect(throws: CycleArchiveFault.self) {
            try await gesture.settle(feature: try inFlightFeature(world), cycleID: world.cycleID, context: context)
        }
        #expect(try world.journal.card(id: active.todo).state == .todo)
        #expect(try world.journal.inFlightCycleID() == world.cycleID)
        #expect(try world.journal.events(ofType: .featureReleased).isEmpty)

        try world.journal.releaseCardLease(cardID: active.todo, runID: holder)
        try await gesture.settle(feature: try inFlightFeature(world), cycleID: world.cycleID, context: context)
        #expect(try world.journal.card(id: active.todo).blockReason == BlockReason.released.rawValue)
        #expect(try world.journal.events(ofType: .featureReleased).count == 1)
    }

    @Test("released on a Partial Landing: worktree release is a no-op, abandoned repositories recorded")
    func releasedOnAPartialLanding() async throws {
        let world = try await makeSettleWorld(landed: true)
        try world.journal.recordLanding(featureID: world.featureID, repository: "backend", mainlineCommit: "c1")
        try world.journal.recordPullRequest(
            featureID: world.featureID, repository: "mobile", url: nil, nightID: world.previousNightID, runID: RunID()
        )
        await world.seedFeatureIssueState(SettleValue.released.rawValue)
        let context = try world.makeContext()
        let feature = try inFlightFeature(world)

        try await FeatureSettleGesture().settle(feature: feature, cycleID: world.cycleID, context: context)

        #expect(world.workspace.removeCalls.isEmpty)
        let row = try settleFeatureRow(world.journal, featureID: world.featureID)
        #expect(row.releasedAt != nil)
        let events = try world.journal.events(ofType: .featureReleased)
        guard case .featureReleased(_, _, _, _, let abandoned, _) = events[0].event else {
            Issue.record("expected featureReleased")
            return
        }
        // "backend" landed, so it is not abandoned; "mobile" has a pull request but no landing.
        #expect(abandoned == ["mobile"])
    }

    @Test(
        "kept in flight is not honoured where only released is offered: a Partial Landing, or every Card Cancelled",
        arguments: [(true, false), (true, true), (false, true)]
    )
    func keptInFlightNotHonouredWhereOnlyReleasedIsOffered(landed: Bool, allCancelled: Bool) async throws {
        let world = try await makeSettleWorld(landed: landed, allCancelled: allCancelled)
        await world.seedFeatureIssueState(SettleValue.keptInFlight.rawValue)
        let context = try world.makeContext()
        let feature = try inFlightFeature(world)

        try await FeatureSettleGesture().settle(feature: feature, cycleID: world.cycleID, context: context)

        #expect(try world.journal.events(ofType: .featureSettled).isEmpty)
        #expect(try world.journal.events(ofType: .featureReleased).isEmpty)
        let notHonoured = try world.journal.events(ofType: .settleValueNotHonoured)
        #expect(notHonoured.count == 1)
        guard case .settleValueNotHonoured(let featureIssueID, let value, _) = notHonoured[0].event else {
            Issue.record("expected settleValueNotHonoured")
            return
        }
        #expect(featureIssueID == "FEAT-1")
        #expect(value == SettleValue.keptInFlight.rawValue)
        // Treated as unsettled: the one comment states only `released` is offered.
        #expect(await world.boards.writing.createCommentCalls == 1)
        let comment = try #require(await world.boards.writing.comments.first)
        #expect(comment.body.contains(SettleValue.released.rawValue))
        #expect(!comment.body.contains(SettleValue.keptInFlight.rawValue))
    }

    @Test("unsettled: only the keyed SettleGestureComment is posted, once")
    func unsettledPostsOnlyTheComment() async throws {
        let world = try await makeSettleWorld()
        await world.seedFeatureIssueState("Some Other State")
        let context = try world.makeContext()
        let gesture = FeatureSettleGesture()

        try await gesture.settle(feature: try inFlightFeature(world), cycleID: world.cycleID, context: context)
        try await gesture.settle(feature: try inFlightFeature(world), cycleID: world.cycleID, context: context)

        #expect(try world.journal.events(ofType: .featureSettled).isEmpty)
        #expect(try world.journal.events(ofType: .featureReleased).isEmpty)
        #expect(await world.boards.writing.createCommentCalls == 1)
        let comment = try #require(await world.boards.writing.comments.first)
        #expect(comment.body.contains(SettleValue.keptInFlight.rawValue))
        #expect(comment.body.contains(SettleValue.released.rawValue))
        #expect(!comment.body.localizedCaseInsensitiveContains("landed"))
    }

    @Test("Releasing twice writes nothing more")
    func releasingTwiceIsIdempotent() async throws {
        let world = try await makeSettleWorld()
        let active = try await world.seedActiveCards()
        await world.seedFeatureIssueState(SettleValue.released.rawValue)
        let context = try world.makeContext()
        let gesture = FeatureSettleGesture()

        try await gesture.settle(feature: try inFlightFeature(world), cycleID: world.cycleID, context: context)
        let stateEvents = try world.journal.events(ofType: .cardStateTransitioned).count
        let boardUpdates = await world.boards.writing.updateCalls
        let feature = try settleFeatureRecord(world.journal, featureID: world.featureID)
        try await gesture.settle(feature: feature, cycleID: world.cycleID, context: context)

        #expect(try world.journal.events(ofType: .featureReleased).count == 1)
        #expect(try world.journal.events(ofType: .cardStateTransitioned).count == stateEvents)
        #expect(await world.boards.writing.updateCalls == boardUpdates)
        #expect(try world.journal.card(id: active.todo).stateVersion == 1)
        #expect(try world.journal.card(id: active.inProgress).stateVersion == 1)
        #expect(await world.boards.writing.createCommentCalls == 1)
    }

    // MARK: - Helpers

    private func inFlightFeature(_ world: SettleWorld) throws -> FeatureRecord {
        try #require(try world.journal.inFlightFeature()).feature
    }
}

private func assertReleasedActiveCards(
    _ world: SettleWorld, active: (todo: Int64, inProgress: Int64), comment: String
) async throws {
    for (cardID, epoch) in [(active.todo, 3), (active.inProgress, 4)] {
        let card = try world.journal.card(id: cardID)
        #expect(card.state == .blocked)
        #expect(card.blockReason == BlockReason.released.rawValue)
        #expect(card.budgetEpoch == epoch)
        #expect(card.stateVersion == 1)
        #expect(card.boardStateVersion == card.stateVersion)
    }
    for issueID in ["BACK-3", "MOB-3"] {
        let issue = try #require(await world.boards.writing.issue(BoardObjectID(rawValue: issueID)))
        #expect(issue.parent == nil)
    }
    #expect(try world.journal.attemptSummary(cardID: active.inProgress).roundCount == 1)
    #expect(comment.contains("BACK-3"))
    #expect(comment.contains("MOB-3"))
    #expect(comment.contains(BlockReason.released.rawValue))

    let adoptable = try world.journal.blockedCardsLeftByClosedFeatures().map(\.issueID)
    #expect(adoptable.contains("BACK-3"))
    #expect(adoptable.contains("MOB-3"))
    #expect(!adoptable.contains("BACK-1"))
    #expect(!adoptable.contains("MOB-2"))
}

@Suite("Author Act applies the settle seam (P10.9)")
struct AuthorActFeatureSettleGestureTests {
    @Test("A released Feature frees the Act to author afresh, past the predecessor gate")
    func releasedFeatureFreesTheActToAuthorAfresh() async throws {
        let world = try await makeSettleWorld()
        await world.seedFeatureIssueState(SettleValue.released.rawValue)
        let board = ActBoard(
            reading: world.reading, writing: world.boards.writing, provisioning: world.boards.provisioning
        )
        let authoring = ScriptedFeatureAuthoring(outcome: .authored)

        let invocation = EngineInvocation(
            act: .author, mode: .real, nightStart: settleObservingNightStart, journal: world.journal,
            trigger: .scheduled, runID: RunID(), board: board, workspace: world.workspace,
            work: AuthorAct(
                predecessorGate: PredecessorAncestryGate(), authoring: authoring, settle: FeatureSettleGesture()
            ).work
        )
        try await invocation.run()

        #expect(authoring.wasCalled)
        let events = try world.journal.events().map(\.type)
        #expect(!events.contains(.authoringSkippedFeatureInFlight))
        #expect(events.contains(.featureReleased))
        let row = try settleFeatureRow(world.journal, featureID: world.featureID)
        #expect(row.releasedAt != nil)
    }

    @Test("A kept-in-flight Feature still skips authoring: the same quiet Night as any in-flight Feature")
    func keptInFlightFeatureStillSkipsAuthoring() async throws {
        let world = try await makeSettleWorld()
        await world.seedFeatureIssueState(SettleValue.keptInFlight.rawValue)
        let board = ActBoard(
            reading: world.reading, writing: world.boards.writing, provisioning: world.boards.provisioning
        )
        let authoring = ScriptedFeatureAuthoring(outcome: .authored)

        let invocation = EngineInvocation(
            act: .author, mode: .real, nightStart: settleObservingNightStart, journal: world.journal,
            trigger: .scheduled, runID: RunID(), board: board, workspace: world.workspace,
            work: AuthorAct(
                predecessorGate: PredecessorAncestryGate(), authoring: authoring, settle: FeatureSettleGesture()
            ).work
        )
        try await invocation.run()

        #expect(!authoring.wasCalled)
        let events = try world.journal.events().map(\.type)
        #expect(events.contains(.authoringSkippedFeatureInFlight))
        #expect(events.contains(.featureSettled))
    }
}

@Suite("SettleGestureComment and FeatureReleaseComment render (P10.9)")
struct SettleCommentRenderingTests {
    @Test("Both offered values state their ancestry consequence, never that abandoned work landed")
    func bothOfferedStateConsequence() {
        let body = SettleGestureComment(offered: [.keptInFlight, .released]).body()
        #expect(body.contains(SettleValue.keptInFlight.rawValue))
        #expect(body.contains("Released"))
        #expect(body.contains("predecessor-ancestry"))
        #expect(!body.localizedCaseInsensitiveContains("this Feature's work landed"))
    }

    @Test("Only released offered omits kept in flight")
    func onlyReleasedOffered() {
        let body = SettleGestureComment(offered: [.released]).body()
        #expect(!body.contains(SettleValue.keptInFlight.rawValue))
        #expect(body.contains("Released"))
    }

    @Test("The release comment names carried-forward Cards, accepted Cards and abandoned repositories")
    func releaseCommentNamesEverything() {
        let comment = FeatureReleaseComment(
            carriedForward: [.init(issueID: "BACK-2", blockReason: .unanswered)],
            acceptedCards: ["BACK-1"], abandonedRepositories: ["backend"],
            triagedNightStart: NightStart(rawValue: "2026-09-10")!
        )
        let body = comment.body()
        #expect(body.hasPrefix("**Released.**"))
        #expect(body.contains("BACK-2"))
        #expect(body.contains("BACK-1"))
        #expect(body.contains("backend"))
        #expect(!body.localizedCaseInsensitiveContains("this release landed"))
    }
}

func settleFeatureRow(_ journal: JournalStore, featureID: Int64) throws -> (releasedAt: String?, closedBy: String?) {
    try journal.read { db in
        let row = try Row.fetchOne(
            db, sql: "SELECT released_at, closed_by FROM feature WHERE id = ?", arguments: [featureID]
        )!
        return (row["released_at"], row["closed_by"])
    }
}

func settleFeatureRecord(_ journal: JournalStore, featureID: Int64) throws -> FeatureRecord {
    try journal.read { db in
        let row = try Row.fetchOne(db, sql: "SELECT * FROM feature WHERE id = ?", arguments: [featureID])!
        return try JournalStore.featureRecord(from: row)
    }
}
