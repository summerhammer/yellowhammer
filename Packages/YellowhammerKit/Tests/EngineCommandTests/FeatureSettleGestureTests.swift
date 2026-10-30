import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
import GRDB
@testable import Journal
import Repositories
import Testing

// roadmap P22.2 (spec: morning-report/triage-the-morning, "Governing native disposition contract"): a
// Feature Card is settled by its native workflow type — Done (`completed`) or Cancelled — and by nothing
// that resets each day. Never asserts anything model-authored.

@Suite("Feature disposition by native workflow type (P22.2)")
struct FeatureDispositionTests {
    @Test(
        "The native category selects the disposition",
        arguments: [
            (BoardWorkflowStateCategory.backlog, FeatureDisposition.backlog),
            (.triage, .backlog),
            (.unstarted, .ready),
            (.started, .continuing),
            (.completed, .completed),
            (.shelved, .canceled)
        ]
    )
    func categorySelectsTheDisposition(
        category: BoardWorkflowStateCategory, expected: FeatureDisposition
    ) async throws {
        let scope = try await resolvedScope()
        let state = BoardWorkflowState(id: BoardObjectID(rawValue: "any"), name: "Any Name", category: category)

        #expect(FeatureDisposition(workflowState: state, scope: scope) == expected)
    }

    @Test("A renamed completed state is still completed: the type is the selector, not the name")
    func renamedCompletedStateIsCompleted() async throws {
        let scope = try await resolvedScope()
        let state = BoardWorkflowState(id: BoardObjectID(rawValue: "x"), name: "Shipped", category: .completed)

        #expect(FeatureDisposition(workflowState: state, scope: scope) == .completed)
    }

    @Test("The custom Waiting on You and Blocked states win over the generic started type")
    func customStatesAreRecognisedFirst() async throws {
        let scope = try await resolvedScope()
        let waiting = BoardWorkflowState(
            id: try scope.id(for: .waitingOnYou), name: "Waiting on You", category: .started
        )
        let blocked = BoardWorkflowState(id: try scope.id(for: .blocked), name: "Blocked", category: .started)

        #expect(FeatureDisposition(workflowState: waiting, scope: scope) == .waitingOnYou)
        #expect(FeatureDisposition(workflowState: blocked, scope: scope) == .blocked)
    }

    @Test("No state, or a state of no known category, is indeterminate")
    func missingEvidenceIsIndeterminate() async throws {
        let scope = try await resolvedScope()
        let unknown = BoardWorkflowState(id: BoardObjectID(rawValue: "u"), name: "Mystery", category: nil)

        #expect(FeatureDisposition(workflowState: nil, scope: scope) == .indeterminate)
        #expect(FeatureDisposition(workflowState: unknown, scope: scope) == .indeterminate)
    }

    private func resolvedScope() async throws -> BoardStateScope {
        try await BoardStateScope.resolve(using: try await makeBuildActBoards().provisioning)
    }
}

@Suite("Settle a Feature by its native disposition (P22.2)")
struct FeatureSettleGestureTests {
    @Test(
        "A state that is not Done or Cancelled writes nothing, never resets, and posts nothing",
        arguments: [
            ("In Review", BoardWorkflowStateCategory.started),
            ("Backlog", .backlog),
            ("Triage", .triage),
            ("Ready", .unstarted)
        ]
    )
    func standingStatesAreLeftAlone(name: String, category: BoardWorkflowStateCategory) async throws {
        let world = try await makeSettleWorld()
        await world.seedFeatureIssueState(name, category: category)
        let context = try world.makeContext()
        let updatesBefore = await world.boards.writing.updateCalls
        let gesture = FeatureSettleGesture()

        try await gesture.settle(feature: try inFlightFeature(world), cycleID: world.cycleID, context: context)
        try await gesture.settle(feature: try inFlightFeature(world), cycleID: world.cycleID, context: context)

        #expect(try world.journal.inFlightFeature() != nil)
        #expect(await world.boards.writing.updateCalls == updatesBefore)
        #expect(await world.boards.writing.createCommentCalls == 0)
        #expect(try world.journal.events(ofType: .featureCompleted).isEmpty)
        #expect(try world.journal.events(ofType: .featureReleased).isEmpty)
        #expect(try settleNightTriagedAt(world.journal, nightID: world.previousNightID) == nil)
        #expect(try settleNightTriagedAt(world.journal, nightID: context.night.id) == nil)
        #expect(try world.journal.card(id: world.waitingCardID).state == .waitingOnYou)
    }

    @Test("Waiting on You, Blocked and an unread Feature Card hold the slot and write nothing")
    func customAndUnreadStatesHoldTheSlot() async throws {
        let scope = try await BoardStateScope.resolve(using: try await makeBuildActBoards().provisioning)
        for state in [CardState.waitingOnYou, .blocked] {
            let world = try await makeSettleWorld()
            await world.seedFeatureIssue(
                state: BoardWorkflowState(id: try scope.id(for: state), name: state.rawValue, category: .started)
            )
            try await FeatureSettleGesture().settle(
                feature: try inFlightFeature(world), cycleID: world.cycleID, context: try world.makeContext()
            )
            #expect(try world.journal.inFlightFeature() != nil)
            #expect(await world.boards.writing.createCommentCalls == 0)
        }

        let unread = try await makeSettleWorld()
        try await FeatureSettleGesture().settle(
            feature: try inFlightFeature(unread), cycleID: unread.cycleID, context: try unread.makeContext()
        )
        #expect(try unread.journal.inFlightFeature() != nil)
        #expect(await unread.boards.writing.createCommentCalls == 0)
    }

    @Test("Done: unfinished Cards are Blocked `feature completed`, detached, counters kept, one comment")
    func doneCarriesUnfinishedWorkForward() async throws {
        let world = try await makeSettleWorld()
        let active = try await world.seedActiveCards()
        try world.holdWorktree(repository: "backend", pushed: true)
        try world.holdWorktree(repository: "mobile", pushed: false)
        try await world.seedFeatureDone()
        let context = try world.makeContext()
        let feature = try inFlightFeature(world)

        try await FeatureSettleGesture().settle(feature: feature, cycleID: world.cycleID, context: context)

        // Todo and In Progress: Blocked `feature completed`, every counter and the history untouched.
        for (cardID, epoch) in [(active.todo, 3), (active.inProgress, 4)] {
            let card = try world.journal.card(id: cardID)
            #expect(card.state == .blocked)
            #expect(card.blockReason == BlockReason.featureCompleted.rawValue)
            #expect(card.budgetEpoch == epoch)
            #expect(card.stateVersion == 1)
            #expect(card.boardStateVersion == card.stateVersion)
        }
        #expect(try world.journal.attemptSummary(cardID: active.inProgress).roundCount == 1)
        // Waiting on You becomes `reply overdue`; an existing Blocked keeps its reason.
        let waiting = try world.journal.card(id: world.waitingCardID)
        #expect(waiting.blockReason == BlockReason.replyOverdue.rawValue)
        #expect(waiting.budgetEpoch == 2)
        #expect(try world.journal.card(id: world.blockedCardID).blockReason == BlockReason.reviewerRejection.rawValue)

        // Every Blocked Card is detached; Done and Shelved are untouched.
        for issueID in ["BACK-2", "BACK-3", "MOB-1", "MOB-3"] {
            let issue = try #require(await world.boards.writing.issue(BoardObjectID(rawValue: issueID)))
            #expect(issue.parent == nil)
        }
        let done = try #require(await world.boards.writing.issue(BoardObjectID(rawValue: "BACK-1")))
        #expect(done.parent == BoardObjectID(rawValue: "FEAT-1"))

        // The pushed Worktree is released; the one holding unpushed work is kept, never discarded.
        #expect(world.workspace.removeCalls.count == 1)
        let held = try world.journal.worktrees(featureID: world.featureID).filter(\.isHeld)
        #expect(held.map(\.repository) == ["mobile"])

        try await assertClosedByCompletion(world, context: context)
        try await assertCompletionRecord(world)
    }

    /// Closed by completion, distinct from merge and Verification; not abandoned; no Night triaged.
    private func assertClosedByCompletion(_ world: SettleWorld, context: ActContext) async throws {
        let row = try settleFeatureRow(world.journal, featureID: world.featureID)
        #expect(row.closedBy == "completion")
        #expect(row.abandonedAt == nil)
        #expect(try world.journal.inFlightCycleID() == nil)
        #expect(try settleNightTriagedAt(world.journal, nightID: world.previousNightID) == nil)
        #expect(try settleNightTriagedAt(world.journal, nightID: context.night.id) == nil)
        let featureIssue = try #require(await world.boards.writing.issue(BoardObjectID(rawValue: "FEAT-1")))
        #expect(!featureIssue.archived)
    }

    private func assertCompletionRecord(_ world: SettleWorld) async throws {
        let completed = try world.journal.events(ofType: .featureCompleted)
        #expect(completed.count == 1)
        guard case .featureCompleted(_, _, let carried, let accepted, let kept) = completed[0].event else {
            Issue.record("expected featureCompleted")
            return
        }
        #expect(carried == ["BACK-2", "BACK-3", "MOB-1", "MOB-3"])
        #expect(accepted == ["BACK-1"])
        #expect(kept == ["mobile"])
        #expect(try world.journal.events(ofType: .featureReleased).isEmpty)

        // Exactly one narrative comment, naming the carried-forward work and the kept Worktree.
        #expect(await world.boards.writing.createCommentCalls == 1)
        let comment = try #require(await world.boards.writing.comments.first)
        #expect(comment.body.hasPrefix("**\(FeatureCompletionComment.headline).**"))
        for issueID in ["BACK-3", "MOB-3"] { #expect(comment.body.contains(issueID)) }
        #expect(comment.body.contains(BlockReason.featureCompleted.rawValue))
        #expect(comment.body.contains("mobile"))

        // Unfinished work stays adoptable, with its history.
        let adoptable = try world.journal.blockedCardsLeftByClosedFeatures().map(\.issueID)
        #expect(adoptable.contains("BACK-3"))
        #expect(adoptable.contains("MOB-3"))
        #expect(!adoptable.contains("BACK-1"))
    }

    @Test("Completing twice writes nothing more: one comment, one event, no further Card transitions")
    func completingTwiceIsIdempotent() async throws {
        let world = try await makeSettleWorld()
        let active = try await world.seedActiveCards()
        try await world.seedFeatureDone()
        let context = try world.makeContext()
        let gesture = FeatureSettleGesture()

        try await gesture.settle(feature: try inFlightFeature(world), cycleID: world.cycleID, context: context)
        let stateEvents = try world.journal.events(ofType: .cardStateTransitioned).count
        let boardUpdates = await world.boards.writing.updateCalls
        let feature = try settleFeatureRecord(world.journal, featureID: world.featureID)
        try await gesture.settle(feature: feature, cycleID: world.cycleID, context: context)

        #expect(try world.journal.events(ofType: .featureCompleted).count == 1)
        #expect(try world.journal.events(ofType: .cycleArchived).count == 1)
        #expect(try world.journal.events(ofType: .cardStateTransitioned).count == stateEvents)
        #expect(await world.boards.writing.updateCalls == boardUpdates)
        #expect(try world.journal.card(id: active.todo).stateVersion == 1)
        #expect(await world.boards.writing.createCommentCalls == 1)
    }

    @Test("A renamed completed state behaves as Done")
    func renamedCompletedStateCompletes() async throws {
        let world = try await makeSettleWorld()
        await world.seedFeatureIssueState("Shipped", category: .completed)

        try await FeatureSettleGesture().settle(
            feature: try inFlightFeature(world), cycleID: world.cycleID, context: try world.makeContext()
        )

        let row = try settleFeatureRow(world.journal, featureID: world.featureID)
        #expect(row.closedBy == "completion")
        #expect(try world.journal.inFlightCycleID() == nil)
    }

    @Test("A held Card Lease defers completion to the next pass: nothing is released while work may still write")
    func completionIsDeferredWhileACardLeaseIsHeld() async throws {
        let world = try await makeSettleWorld()
        let active = try await world.seedActiveCards()
        try world.holdWorktree(repository: "backend", pushed: true)
        try await world.seedFeatureDone()
        let context = try world.makeContext()
        let holder = RunID()
        _ = try world.journal.claimCardLease(cardID: active.todo, runID: holder)
        let gesture = FeatureSettleGesture()

        await #expect(throws: CycleArchiveFault.self) {
            try await gesture.settle(feature: try inFlightFeature(world), cycleID: world.cycleID, context: context)
        }
        #expect(try world.journal.card(id: active.todo).state == .todo)
        #expect(try world.journal.inFlightCycleID() == world.cycleID)
        #expect(try world.journal.events(ofType: .featureCompleted).isEmpty)
        #expect(world.workspace.removeCalls.isEmpty)
        #expect(await world.boards.writing.createCommentCalls == 0)

        try world.journal.releaseCardLease(cardID: active.todo, runID: holder)
        try await gesture.settle(feature: try inFlightFeature(world), cycleID: world.cycleID, context: context)
        #expect(try world.journal.card(id: active.todo).blockReason == BlockReason.featureCompleted.rawValue)
        #expect(try world.journal.events(ofType: .featureCompleted).count == 1)
        #expect(await world.boards.writing.createCommentCalls == 1)
    }

    @Test("Cancelled: the existing `feature abandoned` salvage, with unpushed work discarded and no closure route")
    func cancelledAbandonsTheFeature() async throws {
        let world = try await makeSettleWorld()
        let active = try await world.seedActiveCards()
        try world.holdWorktree(repository: "backend", pushed: true)
        try world.holdWorktree(repository: "mobile", pushed: false)
        try world.journal.recordPullRequest(
            featureID: world.featureID, repository: "backend", url: "https://github.com/acme/backend/pull/1",
            nightID: world.previousNightID, runID: RunID()
        )
        await world.seedFeatureCancelled()
        let context = try world.makeContext()

        try await FeatureSettleGesture().settle(
            feature: try inFlightFeature(world), cycleID: world.cycleID, context: context
        )

        for (cardID, epoch) in [(active.todo, 3), (active.inProgress, 4)] {
            let card = try world.journal.card(id: cardID)
            #expect(card.state == .blocked)
            #expect(card.blockReason == BlockReason.featureAbandoned.rawValue)
            #expect(card.budgetEpoch == epoch)
        }
        #expect(try world.journal.card(id: world.waitingCardID).blockReason == BlockReason.replyOverdue.rawValue)
        #expect(world.workspace.removeCalls.count == 2)
        let row = try settleFeatureRow(world.journal, featureID: world.featureID)
        #expect(row.abandonedAt != nil)
        #expect(row.closedBy == nil)
        #expect(try world.journal.inFlightCycleID() == nil)
        #expect(try world.journal.events(ofType: .featureCompleted).isEmpty)
        let comment = try #require(await world.boards.writing.comments.first)
        #expect(comment.body.hasPrefix("**Abandoned.**"))
        #expect(comment.body.contains("backend"))

        // An abandoned Feature does not enter the unmerged Feature stack.
        #expect(try world.journal.unmergedFeatureStack().isEmpty)
    }

    @Test("A held Todo Card: `feature completed` on native Done, `feature abandoned` on Cancelled")
    func heldTodoCardIsCarriedForwardOnNativeDisposition() async throws {
        let doneWorld = try await makeSettleWorld()
        let heldOnDone = try await seedHeldTodoCard(doneWorld, budgetEpoch: 3)
        try await doneWorld.seedFeatureDone()
        try await FeatureSettleGesture().settle(
            feature: try inFlightFeature(doneWorld), cycleID: doneWorld.cycleID, context: try doneWorld.makeContext()
        )
        // BACK-3 is held behind BACK-2 (Blocked, not Done): the same-repository hold, not merely "unfinished".
        let doneCard = try doneWorld.journal.card(id: heldOnDone)
        #expect(doneCard.state == .blocked)
        #expect(doneCard.blockReason == BlockReason.featureCompleted.rawValue)
        #expect(doneCard.budgetEpoch == 3)

        // The completion comment names BACK-3 as waiting on BACK-2, by issue id and title.
        let doneComment = try #require(await doneWorld.boards.writing.comments.first)
        let doneLine = try #require(doneComment.body.components(separatedBy: "\n").first { $0.hasPrefix("- BACK-3") })
        #expect(doneLine.contains("It is held behind BACK-2 (\"BACK-2\")."))
        // BACK-2 was already Blocked `reviewer rejection`, not a close's own reason: never itself named held.
        let doneHolderLine = try #require(
            doneComment.body.components(separatedBy: "\n").first { $0.hasPrefix("- BACK-2") }
        )
        #expect(!doneHolderLine.contains("held behind"))

        let cancelWorld = try await makeSettleWorld()
        let heldOnCancel = try await seedHeldTodoCard(cancelWorld, budgetEpoch: 5)
        await cancelWorld.seedFeatureCancelled()
        try await FeatureSettleGesture().settle(
            feature: try inFlightFeature(cancelWorld), cycleID: cancelWorld.cycleID,
            context: try cancelWorld.makeContext()
        )
        let cancelCard = try cancelWorld.journal.card(id: heldOnCancel)
        #expect(cancelCard.state == .blocked)
        #expect(cancelCard.blockReason == BlockReason.featureAbandoned.rawValue)
        #expect(cancelCard.budgetEpoch == 5)

        // The release comment names BACK-3 as waiting on BACK-2 too.
        let cancelComment = try #require(await cancelWorld.boards.writing.comments.first)
        let cancelLine = try #require(
            cancelComment.body.components(separatedBy: "\n").first { $0.hasPrefix("- BACK-3") }
        )
        #expect(cancelLine.contains("It is held behind BACK-2 (\"BACK-2\")."))
    }

    /// Adds a Todo Card to `world`'s backend lane, held behind its existing Blocked BACK-2 (OQ182 item 2).
    private func seedHeldTodoCard(_ world: SettleWorld, budgetEpoch: Int) async throws -> Int64 {
        await world.boards.writing.seed(issue: "BACK-3", description: nil)
        _ = try await world.boards.writing.updateIssue(
            BoardObjectID(rawValue: "BACK-3"), BoardIssueChange(parent: .set(BoardObjectID(rawValue: "FEAT-1")))
        )
        return try insertMergeCard(
            world.journal, cycleID: world.cycleID, issueID: "BACK-3", repository: "backend", state: .todo,
            budgetEpoch: budgetEpoch
        )
    }

    @Test("A tracked Feature Card in a started state is continuing: nothing is posted and the Feature stays in flight")
    func startedStatePostsNothing() async throws {
        let world = try await makeSettleWorld()
        await world.seedFeatureIssueState("In Review", category: .started)
        let gesture = FeatureSettleGesture()
        let context = try world.makeContext()

        try await gesture.settle(feature: try inFlightFeature(world), cycleID: world.cycleID, context: context)

        let row = try settleFeatureRow(world.journal, featureID: world.featureID)
        #expect(row.abandonedAt == nil)
        #expect(row.closedBy == nil)
        #expect(try world.journal.inFlightFeature() != nil)
        #expect(await world.boards.writing.comments.isEmpty)
    }

    @Test("A Cancelled Feature on a Partial Landing records the unlanded repositories as abandoned")
    func cancelledOnAPartialLanding() async throws {
        let world = try await makeSettleWorld(landed: true)
        try world.journal.recordLanding(
            featureID: world.featureID, repository: "backend", landingCommit: "c1",
            mainlineCommit: "c1", evidence: .ancestry
        )
        try world.journal.recordPullRequest(
            featureID: world.featureID, repository: "mobile", url: nil, nightID: world.previousNightID, runID: RunID()
        )
        await world.seedFeatureCancelled()

        try await FeatureSettleGesture().settle(
            feature: try inFlightFeature(world), cycleID: world.cycleID, context: try world.makeContext()
        )

        #expect(world.workspace.removeCalls.isEmpty)
        let events = try world.journal.events(ofType: .featureReleased)
        guard case .featureReleased(_, _, _, _, let abandoned, _) = events[0].event else {
            Issue.record("expected featureReleased")
            return
        }
        #expect(abandoned == ["mobile"])
    }

    private func inFlightFeature(_ world: SettleWorld) throws -> FeatureRecord {
        try #require(try world.journal.inFlightFeature()).feature
    }
}

@Suite("Feature completion copy and Block Reason (P22.2)")
struct FeatureCompletionCopyTests {
    @Test("The completion comment names carried-forward work and a kept Worktree, and claims no success")
    func completionCommentRenders() {
        let body = FeatureCompletionComment(
            carriedForward: [.init(issueID: "BACK-3", blockReason: .featureCompleted)],
            acceptedCards: ["BACK-1"], keptWorktrees: ["mobile"]
        ).body()

        #expect(body.hasPrefix("**Feature completed on Board; unfinished work carried forward.**"))
        #expect(body.contains("BACK-3"))
        #expect(body.contains("mobile"))
        #expect(!body.localizedCaseInsensitiveContains("checks passed"))
        #expect(!body.localizedCaseInsensitiveContains("verified"))
    }

    @Test("`feature completed` and `feature abandoned` keep their counters on re-ready and say how to adopt or drop")
    func blockReasonsPreserveCountersAndNameTheNextAction() {
        #expect(!BlockReason.featureCompleted.resetsBudgetOnReReady)
        #expect(!BlockReason.featureAbandoned.resetsBudgetOnReReady)
        for reason in [BlockReason.featureCompleted, .featureAbandoned] {
            #expect(reason.nextAction.contains("adopt"))
            #expect(reason.nextAction.contains("cancel"))
            #expect(!reason.nextAction.contains("back to Todo"))
        }
        #expect(BlockReason.featureCompleted.blockedNote?.contains("Feature completed on Board") == true)
        #expect(BlockReason.featureAbandoned.blockedNote == nil)
    }

    @Test("The Night Card line for a completion names the Board, not a gesture, and the line for a cancel too")
    func nightCardLinesNameTheBoardDisposition() throws {
        let completed = JournalEvent.featureCompleted(
            cycleID: 1, featureIssueID: "FEAT-1", carriedForward: ["BACK-3"], acceptedCards: [],
            keptWorktrees: ["mobile"]
        )
        let line = try #require(NightCardMaintenance.authoringLine(for: completed))
        #expect(line.contains("completed on the Board"))
        #expect(line.contains("mobile"))
        #expect(!line.localizedCaseInsensitiveContains("unsettled"))

        let released = JournalEvent.featureReleased(
            cycleID: 1, featureIssueID: "FEAT-1", carriedForward: [], acceptedCards: [], abandonedRepositories: [],
            triagedNightID: 1
        )
        let cancelLine = try #require(NightCardMaintenance.authoringLine(for: released))
        #expect(cancelLine.contains("cancelled on the Board"))
    }
}

func settleFeatureRow(_ journal: JournalStore, featureID: Int64) throws -> (abandonedAt: String?, closedBy: String?) {
    try journal.read { db in
        let row = try Row.fetchOne(
            db, sql: "SELECT abandoned_at, closed_by FROM feature WHERE id = ?", arguments: [featureID]
        )!
        return (row["abandoned_at"], row["closed_by"])
    }
}

func settleFeatureRecord(_ journal: JournalStore, featureID: Int64) throws -> FeatureRecord {
    try journal.read { db in
        let row = try Row.fetchOne(db, sql: "SELECT * FROM feature WHERE id = ?", arguments: [featureID])!
        return try JournalStore.featureRecord(from: row)
    }
}
