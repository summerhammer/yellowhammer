import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
@testable import Journal
import Testing

// roadmap P22.5 (spec: feature-authoring/select-the-next-feature, `#halted-authoring-repair`; yellowhammer-spec#113):
// a halted Feature the Operator repaired and moved to Todo resumes as the SAME Feature under the SAME Feature
// Issue, instead of the next author Act authoring a duplicate. Drives whole author Acts over a reading board
// linked to the writing board, so the Operator's moves are what the Delta Read and the Feature Card read see.
// Nothing model-authored is asserted.

/// The halt every scenario starts from: Feature FEAT-1 touches `backend` and `mobile`, and `backend` consumes
/// `mobile`, so the first Night halts it as spanning a Repo Dependency. The Operator's repair is removing that edge.
private let haltedRepositories = ProjectRepositories(
    workingRepos: [
        Repo(
            name: "backend", path: "/repos/backend", role: .backend,
            consumes: [RepoDependency(producer: "mobile", via: .tag)]
        ),
        Repo(name: "mobile", path: "/repos/mobile", role: .mobile)
    ],
    specSource: SpecSource(path: "/repos/spec")
)

private final class RepairWorld {
    let rig: AuthoringRig
    let reading: FakeReadingBoard
    private var previous: ActContext?

    init(selector: ScriptedFeatureSelector? = nil) async throws {
        rig = try await AuthoringRig(selector: selector)
        reading = FakeReadingBoard.quiet(40)
        // Seeded before the link: the reading board names a state from the ones it knew when it was linked.
        await rig.boards.provisioning.seed(state: "Canceled", team: teamID, category: .shelved)
        try await reading.readThrough(rig.boards)
    }

    var journal: JournalStore { rig.journal }
    var writing: FakeWritingBoard { rig.boards.writing }
    let feature = FeatureName(rawValue: "FEAT-1")!

    func context(night: String, repositories: ProjectRepositories = selectionRepositories()) throws -> ActContext {
        if let previous { try journal.releaseActLease(runID: previous.runID) }
        let runID = RunID()
        guard case .claimed = try journal.claimActLease(act: .author, runID: runID, mode: .rehearsal) else {
            throw JournalError.actLeaseLost(runID: runID, holder: nil)
        }
        let opening = try journal.openNight(
            nightStart: try #require(NightStart(rawValue: night)), mode: .rehearsal, act: .author, runID: runID
        )
        let context = ActContext(
            act: .author, mode: .rehearsal, trigger: .scheduled, runID: runID, journal: journal,
            night: opening.night,
            outbox: Outbox(
                journal: journal, board: writing, runID: runID, act: .author, nightID: opening.night.id
            ),
            board: ActBoard(
                reading: reading, writing: writing, provisioning: rig.boards.provisioning
            ),
            mainlines: selectionMainlines(), workspace: nil, repositories: repositories,
            featureBases: selectionFeatureBases(selectionMainlines())
        )
        previous = context
        return context
    }

    /// One author Act, as the Engine runs it.
    func runAuthorAct(
        night: String, repositories: ProjectRepositories = selectionRepositories(), unansweredNightsMax: Int = 3
    ) async throws {
        try await AuthorAct(authoring: rig.selection, unansweredNightsMax: unansweredNightsMax)
            .run(try context(night: night, repositories: repositories))
    }

    /// Night one: the selector chooses FEAT-1 and authoring halts on the Repo Dependency.
    @discardableResult
    func haltTheFeature(night: String = "2026-10-01") async throws -> AuthoringHaltRecord {
        try await runAuthorAct(night: night, repositories: haltedRepositories)
        return try halt()
    }

    func halt() throws -> AuthoringHaltRecord {
        try #require(try journal.authoringHalts(feature: feature).last)
    }

    func issueID() throws -> BoardObjectID {
        BoardObjectID(rawValue: try #require(try halt().issueID))
    }

    func scope() async throws -> BoardStateScope {
        try await BoardStateScope.resolve(using: rig.boards.provisioning)
    }

    func state(of issue: BoardObjectID) async throws -> BoardObjectID? {
        await writing.issue(issue)?.workflowState
    }

    func operatorMoves(_ issue: BoardObjectID, to state: CardState) async throws {
        _ = try await writing.updateIssue(issue, BoardIssueChange(workflowState: try await scope().id(for: state)))
    }

    func operatorCancels(_ issue: BoardObjectID) async throws {
        let states = try await rig.boards.provisioning.workflowStates(team: teamID)
        let canceled = try #require(states.first { $0.name == "Canceled" })
        _ = try await writing.updateIssue(issue, BoardIssueChange(workflowState: canceled.id))
    }

    func featureIssueCount() async -> Int {
        await writing.liveIssues.filter { $0.title == "FEAT-1" }.count
    }

    func comments(on issue: BoardObjectID) async -> [String] {
        await writing.comments.filter { $0.issue == issue }.map(\.body)
    }

    func steps() throws -> [String] {
        try journal.events(ofType: .authoringHaltRepair).compactMap {
            if case .authoringHaltRepair(_, let step, _) = $0.event { return step }
            return nil
        }
    }
}

@Suite("Halted Feature repair: Todo resumes the same Feature (P22.5)")
struct HaltedFeatureRepairTests {
    @Test("spec#113: a repaired halted Feature moved to Todo resumes under the same issue, selecting nothing again")
    func repairedFeatureResumesUnderTheSameIssue() async throws {
        let world = try await RepairWorld()
        let halted = try await world.haltTheFeature()
        let issue = try world.issueID()
        #expect(world.rig.selector.callCount == 1)
        #expect(try await world.state(of: issue) == (try world.scope().id(for: .waitingOnYou)))

        try await world.operatorMoves(issue, to: .todo)
        try await world.runAuthorAct(night: "2026-10-02")

        #expect(world.rig.selector.callCount == 1, "the checkpoint holds the selection, so the selector does not run")
        #expect(await world.featureIssueCount() == 1, "no second Feature Issue")
        let inFlight = try #require(try world.journal.inFlightFeature())
        #expect(inFlight.feature.issueID == issue.rawValue, "the same Feature Issue now carries the Cycle")
        #expect(try tableRowCount(world.journal, table: "cycle") == 1)
        let after = try world.journal.authoringHalts(feature: world.feature)
        #expect(after.first { $0.id == halted.id }?.state == .cleared)
        #expect(try world.steps().contains("accepted"))
        #expect(try world.journal.authoringFaultCount(feature: world.feature).count == Int.zero)
    }

    @Test("Todo alone clears nothing: an invalid repair leaves the same Feature halted, spending nothing")
    func invalidRepairStaysHalted() async throws {
        let world = try await RepairWorld()
        let halted = try await world.haltTheFeature()
        let issue = try world.issueID()
        try await world.operatorMoves(issue, to: .todo)
        let updatesBefore = await world.writing.updateCalls

        try await world.runAuthorAct(night: "2026-10-02", repositories: haltedRepositories)

        let after = try world.halt()
        #expect(after.id == halted.id)
        #expect(after.state == .open, "Todo does not clear the halt")
        #expect(after.unansweredNights == 1, "the clock counted the Night and was not renewed")
        #expect(world.rig.selector.callCount == 1)
        #expect(world.rig.drafting.callCount == 0, "the failing deterministic check runs no model")
        #expect(try tableRowCount(world.journal, table: "attempt") == 0)
        #expect(try world.journal.authoringFaultCount(feature: world.feature).count == Int.zero)
        #expect(try tableRowCount(world.journal, table: "cycle") == 0)
        #expect(await world.featureIssueCount() == 1)
        #expect(try await world.state(of: issue) == (try world.scope().id(for: .waitingOnYou)),
                "the halted position is restored")
        #expect(await world.writing.updateCalls == updatesBefore + 1, "one conditioned write: the restore")
        #expect(try world.steps().contains("invalid"))
        #expect(await world.comments(on: issue).count > 1, "the diagnostic is a comment on the same Feature")
    }

    @Test("A Todo observed on several Acts is one request: the repair is validated once, not per Act")
    func repeatedTodoObservationIsIdempotent() async throws {
        let world = try await RepairWorld()
        try await world.haltTheFeature()
        let issue = try world.issueID()
        try await world.operatorMoves(issue, to: .todo)

        let context = try world.context(night: "2026-10-02", repositories: haltedRepositories)
        try await HaltedFeatureRepair.observe(context: context)
        try await HaltedFeatureRepair.observe(context: context)

        let checkpoint = try #require(try world.journal.authoringHaltCheckpoint(haltID: world.halt().id))
        #expect(checkpoint.repairSeq == 1)
        #expect(checkpoint.hasUnhandledRepairRequest)
        #expect(try world.steps().filter { $0 == "requested" }.count == 1)

        // The invalid validation handles the request; a Todo the Operator left in place is not validated again.
        _ = try await world.rig.selection.selectAndAuthor(context)
        let comments = await world.comments(on: issue).count
        try await world.runAuthorAct(night: "2026-10-03", repositories: haltedRepositories)
        #expect(await world.comments(on: issue).count == comments + 1, "only the Night's own halt comment")
        #expect(try world.steps().filter { $0 == "invalid" }.count == 1)
    }

    @Test("Expiry never writes Blocked over the Operator's Todo, and the checkpoint survives it")
    func expiryKeepsTheOperatorsTodo() async throws {
        let world = try await RepairWorld()
        try await world.haltTheFeature()
        let issue = try world.issueID()
        try await world.operatorMoves(issue, to: .todo)
        let updatesBefore = await world.writing.updateCalls

        // Deferral by an occupied slot keeps the Feature at Todo, so the expiry is all that happens to it.
        try insertInFlightFeature(world.journal)
        try await world.runAuthorAct(night: "2026-10-02", unansweredNightsMax: 0)

        #expect(try world.halt().state == .expired, "expiry is recorded in the Journal")
        #expect(try await world.state(of: issue) == (try world.scope().id(for: .todo)), "and Todo is left alone")
        #expect(await world.writing.updateCalls == updatesBefore, "no Blocked write")
        #expect(try world.journal.authoringHaltCheckpoint(haltID: world.halt().id)?.selection != nil)
    }

    @Test("An expired halt is repaired from Blocked, and an invalid repair keeps it Blocked")
    func expiredHaltRepairs() async throws {
        let world = try await RepairWorld()
        try await world.haltTheFeature()
        let issue = try world.issueID()
        try await world.runAuthorAct(night: "2026-10-02", repositories: haltedRepositories, unansweredNightsMax: 0)
        #expect(try world.halt().state == .expired)
        #expect(try await world.state(of: issue) == (try world.scope().id(for: .blocked)))

        try await world.operatorMoves(issue, to: .todo)
        try await world.runAuthorAct(night: "2026-10-03", repositories: haltedRepositories, unansweredNightsMax: 0)
        #expect(try world.halt().state == .expired, "still halted: the invalid repair does not renew or clear")
        #expect(try await world.state(of: issue) == (try world.scope().id(for: .blocked)))

        try await world.operatorMoves(issue, to: .todo)
        try await world.runAuthorAct(night: "2026-10-04", unansweredNightsMax: 0)
        #expect(try world.journal.inFlightFeature()?.feature.issueID == issue.rawValue)
        #expect(try world.journal.authoringHalts(feature: world.feature).allSatisfy { $0.state == .cleared })
        #expect(await world.featureIssueCount() == 1)
    }

    @Test("The Feature Card's last observed state is kept durably, and a board read replaces it")
    func observedStateIsDurable() async throws {
        let world = try await RepairWorld()
        let halted = try await world.haltTheFeature()
        let issue = try world.issueID()
        let scope = try await world.scope()

        let posted = try #require(try world.journal.authoringHaltCheckpoint(haltID: halted.id))
        #expect(posted.observedStateID == (try scope.id(for: .waitingOnYou)).rawValue)
        #expect(posted.observedCategory == .started)

        try await world.operatorMoves(issue, to: .todo)
        try await HaltedFeatureRepair.observe(context: try world.context(night: "2026-10-02"))

        let read = try #require(try world.journal.authoringHaltCheckpoint(haltID: halted.id))
        #expect(read.observedStateID == (try scope.id(for: .todo)).rawValue)
        #expect(read.observedCategory == .unstarted)
        #expect(read.repairPending)
    }

    @Test("A Blocked halted Feature Card leads its managed content with the Block Reason and the repair to make")
    func blockedHeadline() async throws {
        let world = try await RepairWorld()
        try await world.haltTheFeature()
        let issue = try world.issueID()
        let context = try world.context(night: "2026-10-02")
        try await UnansweredPositionClock.run(context: context, unansweredNightsMax: 0)
        let outbox = try #require(context.outbox)

        try await FeatureRollUpMaintenance.maintainRollUps(
            night: context.night, journal: world.journal, outbox: outbox
        )

        let description = try #require(await world.writing.issue(issue)?.description)
        #expect(description.contains(BlockReason.haltedFeatureHeadline))
        #expect(description.contains("move it to Todo"))
    }

    @Test("A repair is deferred while another Feature is in flight: feedback once, nothing dispatched or accepted")
    func deferredWhileAnotherFeatureIsInFlight() async throws {
        let world = try await RepairWorld()
        try await world.haltTheFeature()
        let issue = try world.issueID()
        try await world.operatorMoves(issue, to: .todo)
        try insertInFlightFeature(world.journal)

        try await world.runAuthorAct(night: "2026-10-02")
        try await world.runAuthorAct(night: "2026-10-03")

        #expect(world.rig.selector.callCount == 1)
        #expect(world.rig.drafting.callCount == 0)
        #expect(try world.steps().filter { $0 == "deferred" }.count == 1, "one feedback per deferral reason")
        #expect(try world.halt().state == .open, "the halt is neither cleared nor accepted")
        #expect(try await world.state(of: issue) == (try world.scope().id(for: .todo)),
                "left as the Operator set it")
        #expect(try tableRowCount(world.journal, table: "attempt") == 0)
    }

    @Test("A halted Feature Card completed or canceled before any Cycle resolves as that disposition", arguments: [
        "Done", "Canceled"
    ])
    func terminalBeforeAnyCycle(disposition: String) async throws {
        let world = try await RepairWorld()
        let halted = try await world.haltTheFeature()
        let issue = try world.issueID()
        if disposition == "Done" {
            try await world.operatorMoves(issue, to: .done)
        } else {
            try await world.operatorCancels(issue)
        }
        let before = await world.writing.writes(to: issue).count

        // The name is selected again on the next Night and halts again on the Repo Dependency.
        try await world.runAuthorAct(night: "2026-10-02", repositories: haltedRepositories)

        let all = try world.journal.authoringHalts(feature: world.feature)
        let resolved = try #require(all.first { $0.id == halted.id })
        #expect(resolved.state == .cleared)
        #expect(try world.steps().contains("terminal"))
        #expect(await world.writing.writes(to: issue).count == before, "the Operator's terminal state is untouched")
        #expect(try tableRowCount(world.journal, table: "cycle") == 0, "no phantom Cycle")
        #expect(try tableRowCount(world.journal, table: "feature") == 0, "and no claim of delivery")
        // The Act-end Roll-up leaves the Operator's terminal Feature Card as it is.
        let context = try world.context(night: "2026-10-02")
        try await FeatureRollUpMaintenance.maintainRollUps(
            night: context.night, journal: world.journal, outbox: try #require(context.outbox)
        )
        let description = try #require(await world.writing.issue(issue)?.description)
        #expect(!description.contains("in authoring"))
        // The name selected again is a new Feature on a new Feature Issue, never the terminal one.
        let latest = try world.halt()
        #expect(latest.id != halted.id)
        #expect(latest.issueID != halted.issueID)
    }

    @Test("A Feature Card the Operator moves during validation is never moved back to Todo by the plan")
    func movedDuringValidationIsNotAccepted() async throws {
        let world = try await RepairWorld()
        try await world.haltTheFeature()
        let issue = try world.issueID()
        try await world.operatorMoves(issue, to: .todo)
        let mover = MovingDrafting(
            wrapping: world.rig.drafting, board: world.writing, issue: issue,
            to: try await world.scope().id(for: .blocked)
        )
        let selection = FeatureSelection(
            selector: world.rig.selector,
            transaction: AuthoringTransaction(
                drafting: mover, citations: FakeCitationResolver(), transcribing: FakeContractTranscriber(),
                provenance: FakeProvenanceTester()
            ),
            reselectionsMax: 0
        )

        try await AuthorAct(authoring: selection).run(try world.context(night: "2026-10-02"))

        #expect(try await world.state(of: issue) == (try world.scope().id(for: .blocked)), "the Operator's move stands")
        #expect(try tableRowCount(world.journal, table: "cycle") == 0, "nothing was accepted")
        #expect(try world.halt().state == .open)
        let checkpoint = try #require(try world.journal.authoringHaltCheckpoint(haltID: world.halt().id))
        #expect(checkpoint.hasUnhandledRepairRequest, "the request is read again from a fresh board on the next Act")
        #expect(try world.steps().contains("deferred"))
    }

    @Test("A Feature Card nobody halted is not adopted by being moved to Todo, nor by a comment")
    func arbitraryTodoFeatureIsNotAdopted() async throws {
        let world = try await RepairWorld()
        try await world.haltTheFeature()
        let halted = try world.issueID()
        let scope = try await world.scope()
        let strayReceipt = try await world.writing.createIssue(
            BoardIssueDraft(
                team: scope.team, title: "Stray", description: "x",
                labels: [try #require(world.rig.boards.ids[CardType.featureCard.rawValue])],
                workflowState: try scope.id(for: .todo)
            ),
            clientID: UUID()
        )
        let stray = strayReceipt.id
        _ = try await world.writing.createComment(
            on: halted, body: "an Operator comment, nothing else", clientID: UUID()
        )
        let updatesBefore = await world.writing.updateCalls

        try await world.runAuthorAct(night: "2026-10-02", repositories: haltedRepositories)

        #expect(try world.steps().isEmpty, "no repair is requested for a comment or a stray Todo")
        #expect(await world.writing.writes(to: stray).isEmpty)
        #expect(await world.writing.updateCalls == updatesBefore)
        #expect(try world.journal.authoringHaltCheckpoint(haltID: world.halt().id)?.repairSeq == 0)
    }

    @Test("The checkpoint is recorded before the Feature Card is exposed, and survives a crash after the create")
    func checkpointPrecedesExposure() async throws {
        let world = try await RepairWorld()
        let first = try world.context(night: "2026-10-01", repositories: haltedRepositories)
        let selected = try authoringSelection()
        let cause = AuthoringHaltCause.featureSpansRepoDependency(
            edges: [SpannedRepoDependency(consumer: "backend", producer: "mobile", via: .tag)]
        )
        let crashed = crashing(first, boards: world.rig.boards, afterApplying: 1)

        await #expect(throws: SimulatedCrash.self) {
            _ = try await AuthoringHalt.record(
                feature: world.feature, cause: cause, selection: selected, context: crashed
            )
        }

        let halt = try world.halt()
        #expect(halt.issueID == nil, "the crash came between the board's answer and the Journal hearing of it")
        let checkpoint = try #require(try world.journal.authoringHaltCheckpoint(haltID: halt.id))
        #expect(checkpoint.selection == selected)
        #expect(checkpoint.boardConnection == world.journal.linearWorkspace.rawValue)
        #expect(checkpoint.causeDetail == cause.detail)
        #expect(!checkpoint.transactionID.isEmpty)

        let second = try world.context(night: "2026-10-01", repositories: haltedRepositories)
        _ = try await AuthoringHalt.record(feature: world.feature, cause: cause, selection: selected, context: second)
        #expect(try world.halt().issueID != nil, "the id is persisted once the create is known")
        #expect(await world.featureIssueCount() == 1)
    }

    @Test("A halt recorded before the selector chose a Feature runs the selector pinned to it, and records why")
    func nameOnlyCheckpointRunsThePinnedSelector() async throws {
        let rig = try await AuthoringRig()
        let feature = try #require(FeatureName(rawValue: "FEAT-1"))
        let reading = FakeReadingBoard.quiet(10)
        try await reading.readThrough(rig.boards)
        let halted = try makeContext(rig, reading: reading, night: "2026-10-01")
        _ = try await AuthoringHalt.record(
            feature: feature, cause: .noBackwardCompatibleSeam(seam: "the shared endpoint"), context: halted
        )
        let issueText = try #require(try rig.journal.authoringHalts(feature: feature).last?.issueID)
        let issue = BoardObjectID(rawValue: issueText)
        let todo = try await BoardStateScope.resolve(using: rig.boards.provisioning).id(for: .todo)
        _ = try await rig.boards.writing.updateIssue(issue, BoardIssueChange(workflowState: todo))

        let repair = try makeContext(rig, reading: reading, night: "2026-10-02", previous: halted)
        try await HaltedFeatureRepair.observe(context: repair)
        let outcome = try await rig.selection.selectAndAuthor(repair)

        #expect(outcome == .authored)
        #expect(rig.selector.callCount == 1, "the genuinely missing stage ran")
        #expect(rig.selector.lastRequest?.namedFeature == feature, "pinned to this Feature, never another")
        let detail = try rig.journal.events(ofType: .authoringHaltRepair).compactMap { record -> String? in
            if case .authoringHaltRepair(_, "stage", let detail) = record.event { return detail }
            return nil
        }
        #expect(detail.contains { $0.hasPrefix("selection:") }, "the Journal says why a model stage ran")
        #expect(try rig.journal.inFlightFeature()?.feature.issueID == issue.rawValue)
    }

    @Test("repositories-undetermined halt runs pinnedSelection at Todo, no duplicate Feature (spec#113, #676)")
    func repairingRepositoriesUndeterminedHaltRunsPinnedSelection() async throws {
        let feature = try #require(FeatureName(rawValue: "FEAT-1"))
        let emptySelection = SelectedFeature(
            name: feature, reasoning: "no repos determined", sequence: nil,
            repositories: [], adoptedCardIssueIDs: []
        )
        let validSelection = try authoringSelection()
        let selector = ScriptedFeatureSelector(outcomes: [
            .selected(emptySelection),
            .selected(validSelection)
        ])
        let world = try await RepairWorld(selector: selector)

        // Night 1: selection returns empty repositories, halting as repositories-undetermined.
        try await world.runAuthorAct(night: "2026-10-01")
        let halted = try world.halt()
        #expect(halted.causeKind == "repositories-undetermined")
        #expect(world.rig.selector.callCount == 1)
        let issue = try world.issueID()
        #expect(try await world.state(of: issue) == (try world.scope().id(for: .waitingOnYou)))
        #expect(await world.featureIssueCount() == 1)

        // Operator moves the halted Feature to Todo.
        try await world.operatorMoves(issue, to: .todo)

        // Night 2: repairing the halt runs pinnedSelection instead of reusing the saved empty selection.
        try await world.runAuthorAct(night: "2026-10-02")

        #expect(world.rig.selector.callCount == 2, "the selector ran pinned to the Feature at repair")
        #expect(world.rig.selector.lastRequest?.namedFeature == feature, "pinned to this Feature, never another")
        #expect(await world.featureIssueCount() == 1, "no duplicate Feature was created")
        let inFlight = try #require(try world.journal.inFlightFeature())
        #expect(inFlight.feature.issueID == issue.rawValue, "the same Feature Issue now carries the Cycle")
        #expect(try tableRowCount(world.journal, table: "cycle") == 1)
        let after = try world.journal.authoringHalts(feature: world.feature)
        #expect(after.first { $0.id == halted.id }?.state == .cleared)
        #expect(try world.steps().contains("accepted"))

        let details = try world.journal.events(ofType: .authoringHaltRepair).compactMap { record -> String? in
            if case .authoringHaltRepair(_, "stage", let detail) = record.event { return detail }
            return nil
        }
        #expect(details.contains { $0.hasPrefix("selection:") }, "the Journal says why a model stage ran")
    }
}

private func makeContext(
    _ rig: AuthoringRig, reading: FakeReadingBoard, night: String, previous: ActContext? = nil
) throws -> ActContext {
    if let previous { try rig.journal.releaseActLease(runID: previous.runID) }
    let runID = RunID()
    guard case .claimed = try rig.journal.claimActLease(act: .author, runID: runID, mode: .rehearsal) else {
        throw JournalError.actLeaseLost(runID: runID, holder: nil)
    }
    let opening = try rig.journal.openNight(
        nightStart: try #require(NightStart(rawValue: night)), mode: .rehearsal, act: .author, runID: runID
    )
    return ActContext(
        act: .author, mode: .rehearsal, trigger: .scheduled, runID: runID, journal: rig.journal,
        night: opening.night,
        outbox: Outbox(
            journal: rig.journal, board: rig.boards.writing, runID: runID, act: .author, nightID: opening.night.id
        ),
        board: ActBoard(reading: reading, writing: rig.boards.writing, provisioning: rig.boards.provisioning),
        mainlines: selectionMainlines(), workspace: nil, repositories: selectionRepositories(),
            featureBases: selectionFeatureBases(selectionMainlines())
    )
}

/// Leaves another Feature in flight (an open Cycle) for the one-Feature-in-flight guard.
private func insertInFlightFeature(_ journal: JournalStore) throws {
    try journal.write { db in
        try db.execute(
            sql: "INSERT INTO feature (issue_id, state, created_at) VALUES (?, ?, ?)",
            arguments: ["OTHER-FEATURE", "selected", JournalStore.timestamp(Date())]
        )
        let featureID = db.lastInsertedRowID
        try db.execute(
            sql: "INSERT INTO cycle (feature_id, created_at) VALUES (?, ?)",
            arguments: [featureID, JournalStore.timestamp(Date())]
        )
    }
}

/// A breakdown seam that, while the model "runs", has the Operator move the Feature Card on the board.
private final class MovingDrafting: FeatureBreakdownDrafting, Sendable {
    private let inner: ScriptedBreakdown
    private let board: FakeWritingBoard
    private let issue: BoardObjectID
    private let target: BoardObjectID

    init(wrapping inner: ScriptedBreakdown, board: FakeWritingBoard, issue: BoardObjectID, to target: BoardObjectID) {
        self.inner = inner
        self.board = board
        self.issue = issue
        self.target = target
    }

    var widestRoute: Route? { inner.widestRoute }

    func breakdown(
        for selection: SelectedFeature, mainlines: ResolvedMainlines, context: ActContext,
        accepting: @escaping BreakdownAcceptance
    ) async throws -> FeatureBreakdown {
        _ = try await board.updateIssue(issue, BoardIssueChange(workflowState: target))
        return try await inner.breakdown(for: selection, mainlines: mainlines, context: context, accepting: accepting)
    }
}
