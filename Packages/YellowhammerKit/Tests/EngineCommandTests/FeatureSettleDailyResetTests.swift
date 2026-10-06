import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
import GRDB
@testable import Journal
import Repositories
import Testing

// Issue #93 (roadmap P10.9; Gate G-6): Daily reset of Settle gesture workflow state to unsettled.
// When a Feature is kept in flight on morning T, its Linear workflow state on the board needs to return
// to unsettled (Todo under Gate G-6) prior to morning T+1 so the Operator is presented with the gesture
// on subsequent morning triage.

@Suite("Daily reset of Settle gesture workflow state (Issue #93, P10.9)")
struct FeatureSettleDailyResetTests {
    @Test("reset transitions Kept in Flight back to Todo with Feature label and no block reasons")
    func resetTransitionsKeptInFlightToTodo() async throws {
        let world = try await makeSettleWorld()
        await world.seedFeatureIssueState(SettleValue.keptInFlight.rawValue)
        let context = try world.makeContext()
        let feature = try inFlightFeature(world)

        let didReset = try await FeatureSettleGesture().reset(
            feature: feature, cycleID: world.cycleID, context: context
        )
        #expect(didReset)

        let scope = try await BoardStateScope.resolve(using: world.boards.provisioning)
        let todoStateID = try scope.id(for: .todo)
        let featureLabelID = try #require(scope.labels.cardType[.featureCard])

        let issueID = BoardObjectID(rawValue: "FEAT-1")
        let issue = try #require(await world.boards.writing.issues[issueID])
        #expect(issue.workflowState == todoStateID)
        #expect(issue.labels.contains(featureLabelID))
        for reasonID in scope.labels.blockReason.values {
            #expect(!issue.labels.contains(reasonID))
        }

        let expectedKey = "settle:\(world.cycleID):reset:\(context.night.id)"
        let clientID = OutboxClientID.make(
            projectID: world.journal.projectID, salt: world.journal.outboxSalt, key: expectedKey
        )
        let entry = try world.journal.outboxEntry(clientID: clientID)
        #expect(entry?.state == .applied)
    }

    @Test(
        "reset is a no-op when the Feature Issue is not Kept in Flight",
        arguments: [
            SettleValue.released.rawValue,
            CardState.todo.rawValue,
            "Waiting on You",
            "In Progress"
        ]
    )
    func resetIsNoOpWhenNotInFlightOrNotKeptInFlight(stateName: String) async throws {
        let world = try await makeSettleWorld()
        await world.seedFeatureIssueState(stateName)
        let context = try world.makeContext()
        let feature = try inFlightFeature(world)
        let updatesBefore = await world.boards.writing.updateCalls

        let didReset = try await FeatureSettleGesture().reset(
            feature: feature, cycleID: world.cycleID, context: context
        )
        #expect(!didReset)
        #expect(await world.boards.writing.updateCalls == updatesBefore)
    }

    @Test("reset is a no-op when the issue does not exist on the board")
    func resetIsNoOpWhenIssueNotFound() async throws {
        let world = try await makeSettleWorld()
        let context = try world.makeContext()
        let feature = try inFlightFeature(world)
        let updatesBefore = await world.boards.writing.updateCalls

        let didReset = try await FeatureSettleGesture().reset(
            feature: feature, cycleID: world.cycleID, context: context
        )
        #expect(!didReset)
        #expect(await world.boards.writing.updateCalls == updatesBefore)
    }

    @Test("reset duplicate calls are idempotent and do not post duplicate writes")
    func resetIsIdempotent() async throws {
        let world = try await makeSettleWorld()
        await world.seedFeatureIssueState(SettleValue.keptInFlight.rawValue)
        let context = try world.makeContext()
        let feature = try inFlightFeature(world)

        let firstReset = try await FeatureSettleGesture().reset(
            feature: feature, cycleID: world.cycleID, context: context
        )
        #expect(firstReset)
        let updatesAfterFirst = await world.boards.writing.updateCalls

        // Once the board reflects Todo, a subsequent reset call is a no-op.
        await world.seedFeatureIssueState(CardState.todo.rawValue)
        let secondReset = try await FeatureSettleGesture().reset(
            feature: feature, cycleID: world.cycleID, context: context
        )
        #expect(!secondReset)
        #expect(await world.boards.writing.updateCalls == updatesAfterFirst)
    }

    // MARK: - Helpers

    private func inFlightFeature(_ world: SettleWorld) throws -> FeatureRecord {
        try #require(try world.journal.inFlightFeature()).feature
    }
}

@Suite("Night boundary closeNightIfNeeded resets Settle state (Issue #93, P10.9)")
struct CloseNightSettleResetTests {
    @Test("closing a Night resets a kept-in-flight Feature to Todo")
    func closingNightResetsKeptInFlightFeature() async throws {
        let world = try await makeSettleWorld()
        await world.seedFeatureIssueState(SettleValue.keptInFlight.rawValue)
        let board = ActBoard(
            reading: world.reading, writing: world.boards.writing, provisioning: world.boards.provisioning
        )

        let invocation = EngineInvocation(
            act: .land, mode: .real, nightStart: settleObservingNightStart, journal: world.journal,
            trigger: .forced, runID: RunID(), closesNight: true, board: board, work: { _ in }
        )
        try await invocation.run()

        #expect(try world.journal.currentNight() == nil)
        let closedNight = try #require(try world.journal.nights().last)
        #expect(!closedNight.isOpen)
        #expect(closedNight.nightStart == settleObservingNightStart)

        let scope = try await BoardStateScope.resolve(using: world.boards.provisioning)
        let todoStateID = try scope.id(for: .todo)
        let issue = try #require(await world.boards.writing.issues[BoardObjectID(rawValue: "FEAT-1")])
        #expect(issue.workflowState == todoStateID)
    }

    @Test("an invocation with closesNight: false does not reset the Settle state")
    func nonClosingNightDoesNotResetSettleState() async throws {
        let world = try await makeSettleWorld()
        await world.seedFeatureIssueState(SettleValue.keptInFlight.rawValue)
        let board = ActBoard(
            reading: world.reading, writing: world.boards.writing, provisioning: world.boards.provisioning
        )

        let invocation = EngineInvocation(
            act: .author, mode: .real, nightStart: settleObservingNightStart, journal: world.journal,
            trigger: .scheduled, runID: RunID(), closesNight: false, board: board, workspace: world.workspace,
            work: { _ in }
        )
        try await invocation.run()

        let scope = try await BoardStateScope.resolve(using: world.boards.provisioning)
        let todoStateID = try scope.id(for: .todo)
        let issue = try #require(await world.boards.writing.issues[BoardObjectID(rawValue: "FEAT-1")])
        #expect(issue.workflowState != todoStateID)
    }

    @Test("closing a Night without an in-flight Feature does not post a reset")
    func closingNightWithoutInFlightFeatureDoesNotReset() async throws {
        let world = try await makeSettleWorld(inFlight: false)
        let board = ActBoard(
            reading: world.reading, writing: world.boards.writing, provisioning: world.boards.provisioning
        )

        let invocation = EngineInvocation(
            act: .land, mode: .real, nightStart: settleObservingNightStart, journal: world.journal,
            trigger: .forced, runID: RunID(), closesNight: true, board: board, work: { _ in }
        )
        try await invocation.run()

        // The Night Card was completed, but the Feature Issue was never reset to Todo.
        let feat = await world.boards.writing.issues[BoardObjectID(rawValue: "FEAT-1")]
        #expect(feat?.workflowState == nil)
    }

    @Test("rehearsal Night reset operates safely and transitions state")
    func rehearsalNightResetOperatesSafely() async throws {
        let world = try await makeSettleWorld()
        await world.seedFeatureIssueState(SettleValue.keptInFlight.rawValue)
        let board = ActBoard(
            reading: world.reading, writing: world.boards.writing, provisioning: world.boards.provisioning
        )

        let invocation = EngineInvocation(
            act: .land, mode: .rehearsal, nightStart: settleObservingNightStart, journal: world.journal,
            trigger: .forced, runID: RunID(), closesNight: true, board: board, work: { _ in }
        )
        try await invocation.run()

        #expect(try world.journal.currentNight() == nil)
        let closedNight = try #require(try world.journal.nights().last)
        #expect(!closedNight.isOpen)
        #expect(closedNight.nightStart == settleObservingNightStart)

        let scope = try await BoardStateScope.resolve(using: world.boards.provisioning)
        let todoStateID = try scope.id(for: .todo)
        let issue = try #require(await world.boards.writing.issues[BoardObjectID(rawValue: "FEAT-1")])
        #expect(issue.workflowState == todoStateID)
    }
}

@Suite("Multi-night in-flight triage workflow with daily reset (Issue #93, P10.9)")
struct MultiNightInFlightWorkflowTests {
    let night1Start = settleObservingNightStart
    let night2Start = NightStart(rawValue: "2026-09-13")!

    @Test(
        "Night 1 kept in flight resets to Todo; Morning 2 left unsettled prompts Operator and does not triage Night 1"
    )
    func night1KeptInFlightMorning2LeftUnsettled() async throws {
        let world = try await makeSettleWorld()
        let board = ActBoard(
            reading: world.reading, writing: world.boards.writing, provisioning: world.boards.provisioning
        )
        let authoring = ScriptedFeatureAuthoring(outcome: .authored)

        // Morning 1: Operator kept Feature in flight.
        await world.seedFeatureIssueState(SettleValue.keptInFlight.rawValue)

        // Night 1 Author Act: settles the feature and skips authoring.
        try await EngineInvocation(
            act: .author, mode: .real, nightStart: night1Start, journal: world.journal,
            trigger: .scheduled, runID: RunID(), closesNight: false, board: board, workspace: world.workspace,
            work: AuthorAct(
                predecessorGate: PredecessorAncestryGate(), authoring: authoring, settle: FeatureSettleGesture()
            ).work
        ).run()

        #expect(try settleNightTriagedAt(world.journal, nightID: world.previousNightID) != nil)
        let night1 = try #require(try world.journal.currentNight())
        let night1ID = night1.id

        // Night 1 Land Act at night_end: closes Night 1 and resets settle state to Todo.
        try await EngineInvocation(
            act: .land, mode: .real, nightStart: night1Start, journal: world.journal,
            trigger: .forced, runID: RunID(), closesNight: true, board: board, work: { _ in }
        ).run()

        let scope = try await BoardStateScope.resolve(using: world.boards.provisioning)
        let todoStateID = try scope.id(for: .todo)
        let featIssue = try #require(await world.boards.writing.issues[BoardObjectID(rawValue: "FEAT-1")])
        #expect(featIssue.workflowState == todoStateID)

        // Morning 2: Operator takes NO action, so the board remains in the reset state (Todo / unsettled).
        await world.seedFeatureIssueState(CardState.todo.rawValue)

        let commentsBefore = await world.boards.writing.createCommentCalls

        // Night 2 Author Act: settle reads unsettled -> posts comment, does NOT triage Night 1.
        try await EngineInvocation(
            act: .author, mode: .real, nightStart: night2Start, journal: world.journal,
            trigger: .scheduled, runID: RunID(), closesNight: false, board: board, workspace: world.workspace,
            work: AuthorAct(
                predecessorGate: PredecessorAncestryGate(), authoring: authoring, settle: FeatureSettleGesture()
            ).work
        ).run()

        // Night 1 is still untriaged because Operator did not settle on Morning 2.
        #expect(try settleNightTriagedAt(world.journal, nightID: night1ID) == nil)
        // A settle prompt comment was posted on the Feature Issue.
        #expect(await world.boards.writing.createCommentCalls == commentsBefore + 1)
    }

    @Test("Night 1 kept in flight resets to Todo; Morning 2 settled again triages Night 1 and resets for Morning 3")
    func night1KeptInFlightMorning2SettledAgain() async throws {
        let world = try await makeSettleWorld()
        let board = ActBoard(
            reading: world.reading, writing: world.boards.writing, provisioning: world.boards.provisioning
        )
        let authoring = ScriptedFeatureAuthoring(outcome: .authored)

        // Morning 1: Operator kept Feature in flight.
        await world.seedFeatureIssueState(SettleValue.keptInFlight.rawValue)

        // Night 1 Author Act.
        try await EngineInvocation(
            act: .author, mode: .real, nightStart: night1Start, journal: world.journal,
            trigger: .scheduled, runID: RunID(), closesNight: false, board: board, workspace: world.workspace,
            work: AuthorAct(
                predecessorGate: PredecessorAncestryGate(), authoring: authoring, settle: FeatureSettleGesture()
            ).work
        ).run()

        let night1 = try #require(try world.journal.currentNight())
        let night1ID = night1.id

        // Night 1 Land Act at night_end: closes Night 1 and resets state.
        try await EngineInvocation(
            act: .land, mode: .real, nightStart: night1Start, journal: world.journal,
            trigger: .forced, runID: RunID(), closesNight: true, board: board, work: { _ in }
        ).run()

        // Morning 2: Operator again settles the gesture to Kept in Flight.
        await world.seedFeatureIssueState(SettleValue.keptInFlight.rawValue)

        // Night 2 Author Act: settle reads Kept in Flight -> triages Night 1.
        try await EngineInvocation(
            act: .author, mode: .real, nightStart: night2Start, journal: world.journal,
            trigger: .scheduled, runID: RunID(), closesNight: false, board: board, workspace: world.workspace,
            work: AuthorAct(
                predecessorGate: PredecessorAncestryGate(), authoring: authoring, settle: FeatureSettleGesture()
            ).work
        ).run()

        #expect(try settleNightTriagedAt(world.journal, nightID: night1ID) != nil)

        // Night 2 Land Act at night_end: closes Night 2 and resets state for Morning 3.
        try await EngineInvocation(
            act: .land, mode: .real, nightStart: night2Start, journal: world.journal,
            trigger: .forced, runID: RunID(), closesNight: true, board: board, work: { _ in }
        ).run()

        #expect(try world.journal.currentNight() == nil)
        let night2 = try #require(try world.journal.nights().last)
        #expect(!night2.isOpen)
        #expect(night2.nightStart == night2Start)

        let scope = try await BoardStateScope.resolve(using: world.boards.provisioning)
        let todoStateID = try scope.id(for: .todo)
        let featIssue = try #require(await world.boards.writing.issues[BoardObjectID(rawValue: "FEAT-1")])
        #expect(featIssue.workflowState == todoStateID)
    }
}
