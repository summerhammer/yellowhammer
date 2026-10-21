import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
@testable import Journal
import Synchronization
import Testing

// roadmap P22.9 (spec: board-projection/provision-the-board, "Repeatable migration before validation"): a
// versioned, replayable conversion of what the retired taxonomy still means on TRACKED issues only. Never
// asserts anything model-authored; board writes are asserted through `writing.writes(to:)`.

/// A Settle world (Feature `FEAT-1`, Cards `BACK-1`, `MOB-1`, `BACK-2`, `MOB-2` in its Cycle) plus the retired
/// taxonomy on its team: the two settle states (seeded by ``seedBoardScope(on:team:)``), a `Block Reason`
/// group with one child and an `Override` group with two.
struct LegacyWorld {
    let world: SettleWorld
    let context: ActContext
    let keptInFlight: BoardWorkflowState
    let abandoned: BoardWorkflowState
    let inProgress: BoardObjectID
    let canceled: BoardObjectID
    let blockReasonLabel: BoardObjectID
    let pinHigh: BoardObjectID
    let pinLow: BoardObjectID
    /// How much of the writing board's log predates the migration (the world's own parent links).
    let baseline: Int

    static let high = "claude/opus/high"
    static let low = "codex/gpt-5/low"
    static let card = "BACK-1"

    init(world: SettleWorld) async throws {
        self.world = world
        let provisioning = world.boards.provisioning
        let states = try await provisioning.workflowStates(team: teamID)
        keptInFlight = try #require(states.first { $0.name == LegacyBoardTaxonomy.keptInFlight })
        abandoned = try #require(states.first { $0.name == LegacyBoardTaxonomy.abandoned })
        // The board's own selection, whatever it is called (a tie among started states goes to the lowest id).
        let scope = try await BoardStateScope.resolve(using: provisioning)
        inProgress = try scope.id(for: .inProgress)
        canceled = try #require(scope.canceledState)
        let blockGroup = await provisioning.seed(
            label: LegacyBoardTaxonomy.blockReasonGroup, team: teamID, isGroup: true
        )
        blockReasonLabel = await provisioning.seed(label: "check failure", team: teamID, parent: blockGroup)
        let overrideGroup = await provisioning.seed(
            label: LegacyBoardTaxonomy.overrideGroup, team: teamID, isGroup: true
        )
        pinHigh = await provisioning.seed(label: Self.high, team: teamID, parent: overrideGroup)
        pinLow = await provisioning.seed(label: Self.low, team: teamID, parent: overrideGroup)
        context = try world.makeContext()
        baseline = await world.boards.writing.writeLog.count
        // The Work Card's Managed Block, with the empty Card override line the Journal has not imported.
        await world.boards.writing.edit(
            BoardObjectID(rawValue: Self.card),
            description: ManagedBlockFence.initialDescription(rendered: "Scope: a.txt\n" + CardOverrideField.emptyLine)
        )
    }

    var migration: LegacyBoardMigration {
        LegacyBoardMigration(board: context.board!, outbox: context.outbox!)
    }

    var writing: FakeWritingBoard { world.boards.writing }
    var cardIssue: BoardObjectID { BoardObjectID(rawValue: Self.card) }
    var featureIssue: BoardObjectID { BoardObjectID(rawValue: "FEAT-1") }

    /// The board holds `issue` in `state` with `labels` (names), as a Delta Read would report it.
    func seedReading(
        _ issue: String, state: BoardWorkflowState, labels: [String] = [], parent: String? = nil
    ) async {
        await world.reading.seed(issue: BoardObject(
            id: BoardObjectID(rawValue: issue), key: issue, title: issue, description: nil, workflowState: state,
            labels: labels, parent: parent.map { BoardObjectID(rawValue: $0) },
            url: "https://example.com/\(issue)", createdAt: outboxEpoch, updatedAt: outboxEpoch
        ))
    }

    var todo: BoardWorkflowState {
        BoardWorkflowState(id: BoardObjectID(rawValue: "todo-1"), name: "Todo", category: .unstarted)
    }

    func updates(to issue: BoardObjectID) async -> [BoardIssueChange] {
        await writing.writes(to: issue, since: baseline).compactMap {
            if case .update(let change) = $0, change.description == nil { return change }
            return nil
        }
    }
}

private extension JournalStore {
    func projectConversion() throws -> LegacyBoardConversion? {
        try legacyConversion(issueID: LegacyBoardConversion.projectKey, kind: .project)
    }

    func cardConversion() throws -> LegacyBoardConversion? {
        try legacyConversion(issueID: LegacyWorld.card, kind: .override)
    }
}

@Suite("Legacy Board migration (P22.9)")
struct LegacyBoardMigrationTests {
    // MARK: - Retired settlement states

    @Test("A tracked Feature Card in Kept in Flight moves to the native started state, once")
    func keptInFlightMovesToNativeStarted() async throws {
        let legacy = try await LegacyWorld(world: try await makeSettleWorld())
        await legacy.seedReading("FEAT-1", state: legacy.keptInFlight)

        try await legacy.migration.run()
        try await legacy.migration.run()

        let updates = await legacy.updates(to: legacy.featureIssue)
        #expect(updates == [BoardIssueChange(workflowState: legacy.inProgress)])
        let row = try #require(try legacy.world.journal.legacyConversion(issueID: "FEAT-1", kind: .settle))
        #expect(row.status == .complete)
        #expect(row.version == LegacyBoardMigration.version)
        #expect(try legacy.world.journal.projectConversion()?.status == .complete)
    }

    @Test("A tracked Feature Card in Abandoned moves to native canceled, and the salvage follows")
    func abandonedMovesToCanceledAndSalvageFollows() async throws {
        let legacy = try await LegacyWorld(world: try await makeSettleWorld())
        await legacy.seedReading("FEAT-1", state: legacy.abandoned)

        try await legacy.migration.run()

        #expect(await legacy.updates(to: legacy.featureIssue) == [BoardIssueChange(workflowState: legacy.canceled)])
        // The board now holds the Feature in native canceled: the settle gesture abandons it.
        await legacy.seedReading(
            "FEAT-1", state: BoardWorkflowState(id: legacy.canceled, name: "Canceled", category: .shelved)
        )
        let feature = try #require(try legacy.world.journal.inFlightFeature()).feature
        try await FeatureSettleGesture().settle(
            feature: feature, cycleID: legacy.world.cycleID, context: legacy.context
        )
        #expect(try settleFeatureRow(legacy.world.journal, featureID: legacy.world.featureID).abandonedAt != nil)
    }

    @Test("A migration interrupted after accepting its write replays to the same single write")
    func interruptedMigrationReplaysWithoutDuplicates() async throws {
        let legacy = try await LegacyWorld(world: try await makeSettleWorld())
        await legacy.seedReading("FEAT-1", state: legacy.keptInFlight)
        // What a run killed between accepting and delivering leaves behind: the row and the pending entry.
        let journal = legacy.world.journal
        try journal.recordLegacyConversion(
            issueID: "FEAT-1", kind: .settle, status: .planned, detail: legacy.keptInFlight.id.rawValue,
            version: LegacyBoardMigration.version, runID: legacy.context.runID
        )
        let key = "legacy:v\(LegacyBoardMigration.version):settle:FEAT-1:\(legacy.keptInFlight.id.rawValue)"
        _ = try legacy.context.outbox!.accept(OutboxWrite(
            key: key,
            write: .updateIssue(
                issue: legacy.featureIssue, change: BoardIssueChange(workflowState: legacy.inProgress), undo: nil
            ),
            expectedState: legacy.keptInFlight.id
        ))

        try await legacy.migration.run()
        try await legacy.migration.run()

        #expect(await legacy.updates(to: legacy.featureIssue).count == 1)
        #expect(try journal.outboxEntries(forIssue: "FEAT-1").count == 1)
        #expect(try journal.legacyConversion(issueID: "FEAT-1", kind: .settle)?.status == .complete)
    }

    @Test("A Feature Card the Operator already moved is left where they put it")
    func movedFeatureIsNotOverwritten() async throws {
        let legacy = try await LegacyWorld(world: try await makeSettleWorld())
        await legacy.seedReading("FEAT-1", state: legacy.keptInFlight)
        await legacy.writing.operatorMoves(legacy.featureIssue, to: legacy.todo.id)
        // The reading board now reports what the Operator did.
        await legacy.seedReading("FEAT-1", state: legacy.todo)

        try await legacy.migration.run()

        #expect(await legacy.updates(to: legacy.featureIssue).isEmpty)
    }

    @Test("An issue the Journal does not track is never read or written, whatever state it is in")
    func untrackedIssueIsUntouched() async throws {
        let legacy = try await LegacyWorld(world: try await makeSettleWorld())
        await legacy.seedReading("OTHER-1", state: legacy.keptInFlight, labels: [LegacyWorld.high, "check failure"])
        await legacy.writing.seed(issue: "OTHER-1", description: nil)
        await legacy.seedReading("FEAT-1", state: legacy.todo)

        try await legacy.migration.run()

        #expect(await legacy.writing.writes(to: BoardObjectID(rawValue: "OTHER-1")).isEmpty)
        #expect(try legacy.world.journal.isTrackedIssue("OTHER-1") == false)
        #expect(try legacy.world.journal.isTrackedIssue("FEAT-1"))
    }

    // MARK: - Legacy Override labels

    @Test("A legacy Override label becomes the Card override field when the field is empty")
    func overrideLabelConvertsToTheField() async throws {
        let legacy = try await LegacyWorld(world: try await makeSettleWorld())
        await legacy.seedReading("FEAT-1", state: legacy.todo)
        await legacy.seedReading(LegacyWorld.card, state: legacy.todo, labels: [LegacyWorld.high], parent: "FEAT-1")

        try await legacy.migration.run()

        let description = try #require(await legacy.writing.issue(legacy.cardIssue)?.description)
        #expect(description.contains("\(CardOverrideField.prefix) \(LegacyWorld.high)"))
        let row = try #require(try legacy.world.journal.legacyConversion(issueID: LegacyWorld.card, kind: .override))
        #expect(row.status == .converted)
        #expect(row.detail == LegacyWorld.high)
        // The pin is unassigned only once its intent is in the field.
        #expect(await legacy.updates(to: legacy.cardIssue).contains(BoardIssueChange(removeLabels: [legacy.pinHigh])))
    }

    @Test("An explicit field that disagrees with the pin, or several pins, are a conflict: nothing is chosen")
    func disagreementIsAConflict() async throws {
        for (field, labels) in [
            (["Card override: \(LegacyWorld.low)"], [LegacyWorld.high]),
            ([], [LegacyWorld.high, LegacyWorld.low])
        ] {
            let legacy = try await LegacyWorld(world: try await makeSettleWorld())
            await legacy.seedReading("FEAT-1", state: legacy.todo)
            await legacy.seedReading(LegacyWorld.card, state: legacy.todo, labels: labels, parent: "FEAT-1")
            let card = try legacy.world.journal.card(id: legacy.world.doneCardID)
            try legacy.world.journal.recordCardOverrideLines(cardID: card.id, lines: field)
            let before = await legacy.writing.issue(legacy.cardIssue)?.description

            try await legacy.migration.run()

            #expect(await legacy.writing.issue(legacy.cardIssue)?.description == before)
            #expect(await legacy.updates(to: legacy.cardIssue).isEmpty)
            #expect(try legacy.world.journal.cardOverrideLines(cardID: card.id) == field)
            #expect(try legacy.world.journal.cardConversion()?.status == .conflict)
            let events = try legacy.world.journal.events(ofType: .legacyBoardObserved)
            #expect(events.count == 1)
            guard case .legacyBoardObserved(let kind, let issue, _) = events[0].event else { return }
            #expect(kind == "override-conflict")
            #expect(issue == LegacyWorld.card)
            // The conflict is told once, however many Acts see it.
            try await legacy.migration.run()
            #expect(try legacy.world.journal.events(ofType: .legacyBoardObserved).count == 1)
            #expect(await legacy.writing.comments.count == 1)
        }
    }

    @Test("A field that already says the pin completes the conversion and frees the label")
    func agreeingFieldCompletes() async throws {
        let legacy = try await LegacyWorld(world: try await makeSettleWorld())
        await legacy.seedReading("FEAT-1", state: legacy.todo)
        await legacy.seedReading(LegacyWorld.card, state: legacy.todo, labels: [LegacyWorld.high], parent: "FEAT-1")
        try legacy.world.journal.recordCardOverrideLines(
            cardID: legacy.world.doneCardID, lines: ["Card override: \(LegacyWorld.high)"]
        )

        try await legacy.migration.run()

        #expect(try legacy.world.journal.cardConversion()?.status == .complete)
        #expect(await legacy.updates(to: legacy.cardIssue) == [BoardIssueChange(removeLabels: [legacy.pinHigh])])
    }

    @Test("The Operator's explicit set or clear completes the conversion, and the pin never returns")
    func explicitClearCompletesAndThePinNeverReturns() async throws {
        let legacy = try await LegacyWorld(world: try await makeSettleWorld())
        await legacy.seedReading("FEAT-1", state: legacy.todo)
        await legacy.seedReading(LegacyWorld.card, state: legacy.todo, labels: [LegacyWorld.high], parent: "FEAT-1")
        try await legacy.migration.run()
        let journal = legacy.world.journal

        // The migration's own line coming back through the import is not an edit.
        let own = ["\(CardOverrideField.prefix) \(LegacyWorld.high)"]
        #expect(try journal.noteCardOverrideEdited(issueID: LegacyWorld.card, lines: own) == false)
        #expect(try journal.legacyConversion(issueID: LegacyWorld.card, kind: .override)?.status == .converted)

        // The Operator clears it.
        await legacy.writing.edit(
            legacy.cardIssue,
            description: ManagedBlockFence.initialDescription(rendered: "Scope: a.txt\n" + CardOverrideField.emptyLine)
        )
        #expect(try journal.noteCardOverrideEdited(issueID: LegacyWorld.card, lines: []))
        #expect(try journal.legacyConversion(issueID: LegacyWorld.card, kind: .override)?.status == .complete)

        // A later sync still sees the label (the unassign never landed) and must not restore the pin.
        try journal.recordLegacyConversion(
            issueID: LegacyBoardConversion.projectKey, kind: .project, status: .planned,
            version: LegacyBoardMigration.version, runID: legacy.context.runID
        )
        try await legacy.migration.run()
        let description = try #require(await legacy.writing.issue(legacy.cardIssue)?.description)
        #expect(!description.contains(LegacyWorld.high))
    }

    @Test("Resolving a conflict by an edit completes it too")
    func editingResolvesAConflict() async throws {
        let legacy = try await LegacyWorld(world: try await makeSettleWorld())
        await legacy.seedReading("FEAT-1", state: legacy.todo)
        await legacy.seedReading(
            LegacyWorld.card, state: legacy.todo, labels: [LegacyWorld.high, LegacyWorld.low], parent: "FEAT-1"
        )
        try await legacy.migration.run()
        let edited = try legacy.world.journal.noteCardOverrideEdited(
            issueID: LegacyWorld.card, lines: ["Card override: x/y/z"]
        )
        #expect(edited)
        #expect(try legacy.world.journal.cardConversion()?.status == .complete)
    }

    // MARK: - Queued writes and retired labels

    @Test("A pending write that sets a retired state or adds a retired label is superseded; others are delivered")
    func pendingLegacyWritesAreSuperseded() async throws {
        let legacy = try await LegacyWorld(world: try await makeSettleWorld())
        await legacy.seedReading("FEAT-1", state: legacy.todo)
        let outbox = try #require(legacy.context.outbox)
        let setsState = try outbox.accept(OutboxWrite(
            key: "t:state",
            write: .updateIssue(
                issue: legacy.cardIssue, change: BoardIssueChange(workflowState: legacy.keptInFlight.id), undo: nil
            ),
            revalidates: false
        ))
        let addsLabel = try outbox.accept(OutboxWrite(
            key: "t:label",
            write: .updateIssue(
                issue: legacy.cardIssue, change: BoardIssueChange(addLabels: [legacy.blockReasonLabel]), undo: nil
            ),
            revalidates: false
        ))
        let harmless = try outbox.accept(OutboxWrite(
            key: "t:harmless",
            write: .updateIssue(
                issue: legacy.cardIssue, change: BoardIssueChange(workflowState: legacy.inProgress), undo: nil
            ),
            revalidates: false
        ))

        try await legacy.migration.run()

        let journal = legacy.world.journal
        #expect(try journal.outboxEntry(id: setsState.id)?.state == .superseded)
        #expect(try journal.outboxEntry(id: addsLabel.id)?.state == .superseded)
        #expect(try journal.outboxEntry(id: harmless.id)?.state == .applied)
        #expect(await legacy.updates(to: legacy.cardIssue) == [BoardIssueChange(workflowState: legacy.inProgress)])
    }

    @Test("Retired Block Reason labels are unassigned from tracked issues only; the team label survives")
    func retiredLabelsAreUnassignedFromTrackedIssuesOnly() async throws {
        let legacy = try await LegacyWorld(world: try await makeSettleWorld())
        await legacy.seedReading("FEAT-1", state: legacy.todo, labels: ["check failure"])
        await legacy.seedReading(LegacyWorld.card, state: legacy.todo, labels: ["check failure"], parent: "FEAT-1")
        await legacy.seedReading("OTHER-1", state: legacy.todo, labels: ["check failure"])
        await legacy.writing.seed(issue: "OTHER-1", description: nil)

        try await legacy.migration.run()

        let removal = BoardIssueChange(removeLabels: [legacy.blockReasonLabel])
        #expect(await legacy.updates(to: legacy.featureIssue) == [removal])
        #expect(await legacy.updates(to: legacy.cardIssue) == [removal])
        #expect(await legacy.writing.writes(to: BoardObjectID(rawValue: "OTHER-1")).isEmpty)
        let labels = try await legacy.world.boards.provisioning.labels(team: teamID)
        #expect(labels.contains { $0.id == legacy.blockReasonLabel })
    }

    @Test("A board with no retired taxonomy is a no-op that finishes the migration")
    func cleanBoardFinishesImmediately() async throws {
        let world = try await makeSettleWorld()
        await world.boards.provisioning.remove(state: LegacyBoardTaxonomy.keptInFlight, team: teamID)
        await world.boards.provisioning.remove(state: LegacyBoardTaxonomy.abandoned, team: teamID)
        let context = try world.makeContext()
        let baseline = await world.boards.writing.writeLog.count
        let migration = LegacyBoardMigration(board: context.board!, outbox: context.outbox!)

        try await migration.run()

        #expect(await world.boards.writing.writeLog.count == baseline)
        #expect(try world.journal.projectConversion()?.status == .complete)
    }

    @Test("An Act runs the migration after the Night Card opens and before its work")
    func anActRunsTheMigrationBeforeItsWork() async throws {
        let world = try await makeSettleWorld()
        let legacy = try await LegacyWorld(world: world)
        await legacy.seedReading("FEAT-1", state: legacy.keptInFlight)
        let board = ActBoard(
            reading: world.reading, writing: world.boards.writing, provisioning: world.boards.provisioning
        )
        let seenAtWork = Mutex<[BoardIssueChange]>([])
        let writing = world.boards.writing
        let baseline = legacy.baseline
        let invocation = EngineInvocation(
            act: .author, mode: .real, nightStart: settleObservingNightStart, journal: world.journal,
            trigger: .forced, runID: RunID(), board: board,
            work: { _ in
                let moved = await writing.writes(to: BoardObjectID(rawValue: "FEAT-1"), since: baseline)
                let changes = moved.compactMap { write -> BoardIssueChange? in
                    if case .update(let change) = write { change } else { nil }
                }
                seenAtWork.withLock { $0 = changes }
            }
        )
        // The Context's own lease is not this Act's: release it so the invocation can claim the Project.
        try world.journal.releaseActLease(runID: legacy.context.runID)

        try await invocation.run()

        #expect(seenAtWork.withLock { $0 } == [BoardIssueChange(workflowState: legacy.inProgress)])
    }

    @Test("isShelved is decided by category alone")
    func isShelvedIsByCategory() {
        #expect(BoardWorkflowState(id: BoardObjectID(rawValue: "a"), name: "Cancelled", category: .shelved).isShelved)
        #expect(!BoardWorkflowState(id: BoardObjectID(rawValue: "b"), name: "Shelved", category: .started).isShelved)
        #expect(!BoardWorkflowState(id: BoardObjectID(rawValue: "c"), name: "Shelved", category: nil).isShelved)
    }

    @Test("A retired-state observation reaches the Night Summary's anomalies")
    func retiredStateObservationReachesTheNightSummary() async throws {
        let world = try await makeSettleWorld()
        let context = try world.makeContext()
        try world.journal.append(
            .legacyBoardObserved(kind: "retired-state", issueID: "FEAT-1", detail: LegacyBoardTaxonomy.abandoned),
            act: .author, runID: context.runID, nightID: context.night.id
        )

        let lines = try NightSummary.anomalyLines(night: context.night, journal: world.journal)

        #expect(lines.contains { $0.contains("FEAT-1") && $0.contains(LegacyBoardTaxonomy.abandoned) })
    }
}
