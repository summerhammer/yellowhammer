import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
@testable import Journal
import Testing

// roadmap P22.6 (spec: feature-authoring/select-the-next-feature, `#halted-authoring-repair`): a halt that arises
// after a breakdown keeps that breakdown in its checkpoint, posts the breakdown's Work Cards as repairable draft
// children of the halted Feature Card, and — when the Operator repairs the Feature and its subcards and moves it to
// Todo — validates the snapshot with the same validators as a machine-authored plan and reuses the drafts under
// their existing issue ids. Nothing model-authored is asserted.

private func overlappingBreakdown() throws -> FeatureBreakdown {
    let kind = try authoringKind()
    func card(_ title: String, _ repository: String, contracts: [ContractDraft] = []) -> CardDraft {
        CardDraft(
            repository: repository, kind: kind, title: title, unitOfWork: "Do \(title)",
            brief: "Approach for \(title).", definitionOfDone: [authoringClause("\(title) is done.")],
            contracts: contracts
        )
    }
    // "Mobile one" reads what both backend Work Cards write: the contract-overlap floor halts the Feature.
    return FeatureBreakdown(
        definitionOfDone: [authoringClause("The Feature is done.")],
        cards: [
            card("Backend one", "backend"), card("Backend two", "backend"),
            card("Mobile one", "mobile", contracts: [
                ContractDraft(repository: "backend", paths: ["Sources/Api.swift"])
            ])
        ]
    )
}

private let noScope = "**Scope:** _none declared_"
private let docsScope = "**Scope:** `docs/`"

private final class DraftWorld {
    let rig: AuthoringRig
    let reading: FakeReadingBoard
    let feature = FeatureName(rawValue: "FEAT-1")!
    var descriptionBudget: DescriptionBudget?
    private var previous: ActContext?

    init(backlog: Bool = true) async throws {
        rig = try await AuthoringRig(drafting: ScriptedBreakdown(try overlappingBreakdown()))
        reading = FakeReadingBoard.quiet(40)
        await rig.boards.provisioning.seed(state: "Canceled", team: teamID, category: .shelved)
        if backlog { await rig.boards.provisioning.seed(state: "Backlog", team: teamID, category: .backlog) }
        try await reading.readThrough(rig.boards)
        await reading.scanLinkedIssues()
    }

    var journal: JournalStore { rig.journal }
    var writing: FakeWritingBoard { rig.boards.writing }

    func context(night: String) throws -> ActContext {
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
            outbox: Outbox(journal: journal, board: writing, runID: runID, act: .author, nightID: opening.night.id),
            board: ActBoard(
                reading: reading, writing: writing, provisioning: rig.boards.provisioning,
                descriptionBudget: descriptionBudget
            ),
            mainlines: selectionMainlines(), workspace: nil, repositories: selectionRepositories(),
            featureBases: selectionFeatureBases(selectionMainlines())
        )
        previous = context
        return context
    }

    func runAuthorAct(night: String) async throws {
        try await AuthorAct(authoring: rig.selection, unansweredNightsMax: 3).run(try context(night: night))
    }

    @discardableResult
    func haltTheFeature() async throws -> AuthoringHaltRecord {
        try await runAuthorAct(night: "2026-10-01")
        return try halt()
    }

    func halt() throws -> AuthoringHaltRecord { try #require(try journal.authoringHalts(feature: feature).last) }
    func issueID() throws -> BoardObjectID { BoardObjectID(rawValue: try #require(try halt().issueID)) }
    func scope() async throws -> BoardStateScope { try await BoardStateScope.resolve(using: rig.boards.provisioning) }

    func children() async throws -> [FakeWritingBoard.Issue] {
        let parent = try issueID()
        return await writing.liveIssues.filter { $0.parent == parent }.sorted { $0.title < $1.title }
    }

    func child(_ title: String) async throws -> FakeWritingBoard.Issue {
        try #require(await children().first { $0.title == title })
    }

    func operatorMoves(_ issue: BoardObjectID, to state: CardState) async throws {
        _ = try await writing.updateIssue(issue, BoardIssueChange(workflowState: try await scope().id(for: state)))
    }

    func operatorCancels(_ issue: BoardObjectID) async throws {
        let states = try await rig.boards.provisioning.workflowStates(team: teamID)
        let canceled = try #require(states.first { $0.name == "Canceled" })
        _ = try await writing.updateIssue(issue, BoardIssueChange(workflowState: canceled.id))
    }

    func operatorEdits(_ title: String, replacing old: String, with new: String) async throws {
        let issue = try await child(title)
        let description = try #require(issue.description)
        #expect(description.contains(old))
        await writing.edit(issue.id, description: description.replacingOccurrences(of: old, with: new))
    }

    func operatorEditsFeature(replacing old: String, with new: String) async throws {
        let issue = try issueID()
        let object = try #require(await writing.issue(issue))
        let description = try #require(object.description)
        #expect(description.contains(old))
        await writing.edit(issue, description: description.replacingOccurrences(of: old, with: new))
    }

    func operatorEditsFeature(description: String) async throws {
        let issue = try issueID()
        await writing.edit(issue, description: description)
    }

    func featureDescription() async throws -> String {
        let issue = try issueID()
        let object = try #require(await writing.issue(issue))
        return try #require(object.description)
    }

    /// The Operator writes a new Work Card beneath the halted Feature Card, from the same draft shape.
    @discardableResult
    func operatorAdds(_ title: String, repository: String, scope: String) async throws -> BoardObjectID {
        let card = CardDraft(
            repository: repository, kind: try authoringKind(), title: title, unitOfWork: "Do \(title)",
            brief: "Approach for \(title).", definitionOfDone: [authoringClause("\(title) is done.")]
        )
        let state = try await self.scope()
        let receipt = try await writing.createIssue(
            BoardIssueDraft(
                team: teamID, title: title,
                description: HaltDrafts.description(of: card).replacingOccurrences(of: noScope, with: scope),
                parent: try issueID(), labels: [try #require(state.labels.cardType[.workCard])]
            ),
            clientID: UUID()
        )
        return receipt.id
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

    /// The Operator's repair of the overlap: both backend drafts declare a scope that Mobile one's contract is
    /// outside of; Backend two is canceled; a new backend Work Card is added.
    func repairTheOverlap() async throws -> BoardObjectID {
        try await operatorEdits("Backend one", replacing: noScope, with: docsScope)
        try await operatorCancels(try await child("Backend two").id)
        let added = try await operatorAdds("Backend extra", repository: "backend", scope: docsScope)
        try await operatorMoves(try issueID(), to: .todo)
        return added
    }
}

@Suite("Halted Feature repair: draft children (P22.6)")
struct HaltedFeatureDraftRepairTests {
    @Test("A halt after a breakdown checkpoints it, then posts repairable draft Work Cards under the Feature Card",
          arguments: [true, false])
    func haltPostsDrafts(backlog: Bool) async throws {
        let world = try await DraftWorld(backlog: backlog)
        let halted = try await world.haltTheFeature()
        let issue = try world.issueID()

        let checkpoint = try #require(try world.journal.authoringHaltCheckpoint(haltID: halted.id))
        #expect(checkpoint.breakdown?.cards.count == 3, "the breakdown is in the checkpoint")
        let drafts = try world.journal.authoringHaltDrafts(haltID: halted.id)
        #expect(drafts.count == 3)
        #expect(drafts.allSatisfy { $0.issueID != nil && $0.source == .authored }, "every returned id is recorded")

        let children = try await world.children()
        #expect(children.map(\.title) == ["Backend one", "Backend two", "Mobile one"])
        let scope = try await world.scope()
        let states = try await world.rig.boards.provisioning.workflowStates(team: teamID)
        let hold = states.first { $0.category == .backlog }
        for child in children {
            #expect(child.parent == issue)
            #expect(child.labels.contains(try #require(scope.labels.cardType[.workCard])), "Card Type Work Card")
            #expect(child.workflowState == hold?.id, "the native backlog state when one resolves, else the default")
            #expect(try #require(child.description).contains(HaltDrafts.headline))
        }
        // A draft is not a Card: nothing dispatches it, no Cycle counts it, no clock reads it.
        #expect(try world.journal.cards().isEmpty)
        #expect(try tableRowCount(world.journal, table: "cycle") == 0)
        #expect(try world.journal.inFlightFeature() == nil)
        #expect(world.rig.drafting.callCount == 1)
    }

    @Test("A crash after the checkpoint and some creates replays to the same drafts, none created twice")
    func crashBetweenCheckpointAndCreatesReplays() async throws {
        let world = try await DraftWorld()
        let crashed = crashing(try world.context(night: "2026-10-01"), boards: world.rig.boards, afterApplying: 4)
        await #expect(throws: SimulatedCrash.self) { _ = try await world.rig.selection.selectAndAuthor(crashed) }

        let halted = try world.halt()
        #expect(try world.journal.authoringHaltCheckpoint(haltID: halted.id)?.breakdown != nil,
                "the breakdown was checkpointed before any draft was posted")
        let before = try world.journal.authoringHaltDrafts(haltID: halted.id)
        #expect(before.count == 3 && before.contains { $0.issueID == nil }, "a create's id was not heard of")

        try await HaltedFeatureRepair.observe(context: try world.context(night: "2026-10-01"))

        let after = try world.journal.authoringHaltDrafts(haltID: halted.id)
        #expect(after.allSatisfy { $0.issueID != nil })
        #expect(try await world.children().count == 3, "exactly the checkpointed drafts, none twice")
        #expect(Set(after.compactMap(\.issueID)) == Set(try await world.children().map(\.id.rawValue)))
    }

    @Test("Operator edits one draft, cancels another and adds a child: the Cycle holds exactly those issue ids")
    func repairedDraftsBecomeTheCycle() async throws {
        let world = try await DraftWorld()
        let halted = try await world.haltTheFeature()
        let issue = try world.issueID()
        let one = try await world.child("Backend one").id
        let two = try await world.child("Backend two").id
        let mobile = try await world.child("Mobile one").id
        let added = try await world.repairTheOverlap()
        let createsBefore = await world.writing.createIssueCalls

        try await world.runAuthorAct(night: "2026-10-02")

        #expect(Set(try world.journal.cards().map(\.issueID)) == Set([one, mobile, added].map(\.rawValue)))
        #expect(try world.journal.cards().count == 3, "the canceled draft is an intentional exclusion")
        #expect(await world.writing.createIssueCalls == createsBefore, "nothing is created anew")
        #expect(await world.writing.liveIssues.filter { $0.title == "FEAT-1" }.count == 1)
        #expect(try world.journal.inFlightFeature()?.feature.issueID == issue.rawValue)
        #expect(try tableRowCount(world.journal, table: "cycle") == 1)
        let cleared = try world.journal.authoringHalts(feature: world.feature).first { $0.id == halted.id }
        #expect(cleared?.state == .cleared)
        #expect(world.rig.drafting.callCount == 1, "no model call: every stage already had its output")
        #expect(world.rig.selector.callCount == 1)
        #expect(try world.journal.authoringFaultCount(feature: world.feature).count == Int.zero)
        let scope = try await world.scope()
        #expect(await world.writing.issue(one)?.workflowState == (try scope.id(for: .todo)), "accepted work is Todo")
        #expect(await world.writing.issue(two)?.workflowState != (try scope.id(for: .todo)), "the canceled stays")
        #expect(try #require(await world.writing.issue(one)?.description).contains(HaltDrafts.headline) == false)
        let row = try #require(try world.journal.card(issueID: one.rawValue))
        #expect(try world.journal.declaredScope(cardID: row.id) == ["docs/"], "the edited scope is accepted")
        let admitted = try world.steps().first { $0 == "admitted" }
        #expect(admitted != nil)
        #expect(try world.journal.authoringHaltDrafts(haltID: halted.id).contains { $0.admittedRevision != nil })
    }

    @Test("Todo observed again after acceptance changes nothing: one Feature, one Cycle, the same Work Cards")
    func repeatedIntakeIsIdempotent() async throws {
        let world = try await DraftWorld()
        try await world.haltTheFeature()
        try await world.repairTheOverlap()
        try await world.runAuthorAct(night: "2026-10-02")
        let cards = Set(try world.journal.cards().map(\.issueID))
        let issues = await world.writing.liveIssues.count
        let creates = await world.writing.createIssueCalls

        try await world.runAuthorAct(night: "2026-10-03")
        try await HaltedFeatureRepair.observe(context: try world.context(night: "2026-10-03"))

        #expect(Set(try world.journal.cards().map(\.issueID)) == cards)
        #expect(try tableRowCount(world.journal, table: "cycle") == 1)
        #expect(try tableRowCount(world.journal, table: "feature") == 1)
        #expect(await world.writing.liveIssues.count == issues)
        #expect(await world.writing.createIssueCalls == creates)
        #expect(try world.steps().filter { $0 == "accepted" }.count == 1)
    }

    private enum InvalidEdit: CaseIterable {
        case overlappingScope, unknownRepository, overDescriptionLimit
    }

    @Test("An invalid repair keeps the drafts and edits, names the child and rule, and spends nothing",
          arguments: InvalidEdit.allCases)
    private func invalidRepairStaysHalted(edit: InvalidEdit) async throws {
        let world = try await DraftWorld()
        let halted = try await world.haltTheFeature()
        let issue = try world.issueID()
        switch edit {
        case .overlappingScope:
            break
        case .unknownRepository:
            try await world.operatorEdits(
                "Mobile one", replacing: "**Repository:** `mobile`", with: "**Repository:** `nowhere`"
            )
        case .overDescriptionLimit:
            try await world.operatorEdits("Backend one", replacing: noScope, with: docsScope)
            try await world.operatorEdits("Backend two", replacing: noScope, with: docsScope)
            world.descriptionBudget = try DescriptionBudget(
                configured: 300, limit: BoardDescriptionLimit(maximum: 250_000, unit: .characters)
            )
        }
        let descriptions = try await world.children().map(\.description)
        try await world.operatorMoves(issue, to: .todo)

        try await world.runAuthorAct(night: "2026-10-02")

        let after = try world.halt()
        #expect(after.id == halted.id)
        #expect(after.state == .open, "Todo does not clear the halt")
        #expect(try await world.children().map(\.description) == descriptions, "the Operator's edits are intact")
        #expect(try await world.children().count == 3)
        #expect(world.rig.drafting.callCount == 1, "no model call")
        #expect(try world.journal.authoringFaultCount(feature: world.feature).count == Int.zero)
        #expect(try tableRowCount(world.journal, table: "attempt") == 0)
        #expect(try tableRowCount(world.journal, table: "cycle") == 0)
        #expect(try world.journal.cards().isEmpty, "no invalid draft is ever dispatched")
        #expect(try world.steps().contains("invalid"))
        #expect(try await world.state(of: issue) == (try world.scope().id(for: .waitingOnYou)))
        let diagnostic = try #require(try world.journal.authoringHaltCheckpoint(haltID: halted.id)?.repairDiagnostic)
        let comment = try #require(await world.comments(on: issue).last { $0.contains("is not accepted") })
        #expect(comment.contains("What to fix"))
        switch edit {
        case .overlappingScope: #expect(diagnostic.contains("Mobile one") && diagnostic.contains("Backend"))
        case .unknownRepository: #expect(diagnostic.contains("Mobile one") && diagnostic.contains("nowhere"))
        case .overDescriptionLimit: #expect(diagnostic.contains(DescriptionBudgetOverrun.marker))
        }
    }

    @Test("A draft edited between validation and acceptance accepts nothing and keeps the edit")
    func childEditedBeforeAcceptance() async throws {
        let world = try await DraftWorld()
        let halted = try await world.haltTheFeature()
        try await world.repairTheOverlap()
        let context = try world.context(night: "2026-10-02")
        try await HaltedFeatureRepair.observe(context: context)
        let checkpoint = try #require(try world.journal.authoringHaltCheckpoint(haltID: halted.id))
        let snapshot = try #require(
            try await HaltRepairSnapshot.take(halt: halted, checkpoint: checkpoint, context: context)
        )
        #expect(snapshot.problems.isEmpty)
        let plan = AuthoringPlan(
            writes: [],
            record: FeatureAuthoringAcceptedPayload(
                name: "FEAT-1", groupKey: "authoring:test", featureKey: "feature:test", nightID: context.night.id,
                cards: [], adoptions: [], bases: []
            ),
            reusedFeatureIssue: try world.issueID(), repairSnapshot: snapshot
        )

        // Unchanged: the plan is admitted, with the exact revisions recorded.
        #expect(try await HaltedFeatureRepair.revalidateBeforeAcceptance(plan, context: context) == nil)
        #expect(try world.journal.authoringHaltDrafts(haltID: halted.id).contains { $0.admittedRevision != nil })

        // The Operator edits a child after validation: nothing is accepted.
        try await world.operatorEdits("Mobile one", replacing: "Approach for Mobile one.", with: "Approach, revised.")
        let outcome = try await HaltedFeatureRepair.revalidateBeforeAcceptance(plan, context: context)
        #expect(outcome == .authoringPending)
        #expect(try world.steps().contains("deferred"))
        #expect(try tableRowCount(world.journal, table: "cycle") == 0)
        #expect(try await world.child("Mobile one").description?.contains("Approach, revised.") == true)
    }

    @Test("Only a child beneath the exact tracked halted Feature Card of this Board Connection is admitted")
    func admission() async throws {
        let world = try await DraftWorld()
        let halted = try await world.haltTheFeature()
        let issue = try world.issueID()
        let states = try await world.rig.boards.provisioning.workflowStates(team: teamID)
        let state = try #require(states.first)
        func object(_ id: String, parent: BoardObjectID?) -> BoardObject {
            BoardObject(
                id: BoardObjectID(rawValue: id), key: "ENG-\(id)", title: id, description: nil,
                workflowState: state, labels: [], parent: parent, url: "https://linear.app/x/\(id)",
                createdAt: deltaEpoch, updatedAt: deltaEpoch.addingTimeInterval(10)
            )
        }
        func read(_ objects: [BoardObject]) async throws -> DeltaReadReport {
            let context = try world.context(night: "2026-10-02")
            let delta = DeltaRead(
                journal: world.journal, board: FakeReadingBoard([page(objects: objects)]), runID: context.runID,
                act: .author, horizon: { .distantFuture }
            )
            guard case .read(let report) = try await delta.perform() else { throw SimulatedCrash() }
            return report
        }

        let first = try await read([
            object("orphan", parent: nil), object("foreign", parent: BoardObjectID(rawValue: "another-feature")),
            object("operator-child", parent: issue)
        ])
        #expect(first.haltDraftChildren.map(\.id.rawValue) == ["operator-child"])
        #expect(Set(first.unknownObjects.map(\.id.rawValue)) == ["orphan", "foreign"], "stay unknown")
        let rows = try world.journal.authoringHaltDrafts(haltID: halted.id)
        #expect(rows.contains { $0.issueID == "operator-child" && $0.source == .board })
        #expect(!rows.contains { $0.issueID == "orphan" || $0.issueID == "foreign" })
        #expect(try world.journal.cards().isEmpty, "an admitted child is still a draft, not a Card")

        // A halt of another Board Connection is not this Project's tracked halt.
        try world.journal.write { db in
            try db.execute(sql: "UPDATE authoring_halt_checkpoint SET board_connection = 'someone-else'")
        }
        let second = try await read([object("other-project-child", parent: issue)])
        #expect(second.haltDraftChildren.isEmpty)
        #expect(second.unknownObjects.map(\.id.rawValue) == ["other-project-child"])
    }

    @Test("A halt writes Feature-level Definition of Done to Feature Card, idempotent, and observe finishes it (c1)")
    func haltPostsFeatureDefinitionOfDone() async throws {
        let world = try await DraftWorld()
        let halted = try await world.haltTheFeature()

        let desc = try await world.featureDescription()
        #expect(desc.contains(FeatureAuthoringProse.start))
        #expect(desc.contains(FeatureAuthoringProse.end))
        #expect(desc.contains(HaltDrafts.featureHeadline))
        #expect(desc.contains("## Definition of done"))
        #expect(desc.contains("- [ ] The Feature is done. (resolvable/story)"))
        #expect(!desc.contains("<!-- yh:clause:"), "no cid markers on draft clauses")

        // The write went through a deterministic Outbox key.
        let key = HaltDrafts.featureDefinitionOfDoneKey(feature: world.feature, haltID: halted.id)
        let outbox = try #require(try world.context(night: "2026-10-01").outbox)
        let clientID = outbox.clientID(for: key)
        let entry = try #require(try world.journal.outboxEntry(clientID: clientID))
        #expect(entry.state == .applied)

        // It is never sent twice on replay.
        let writesBefore = await world.writing.updateCalls
        try await HaltDrafts.ensureFeatureDefinitionOfDonePosted(
            halt: halted, context: try world.context(night: "2026-10-01")
        )
        #expect(await world.writing.updateCalls == writesBefore, "alreadyApplied write is never sent again")

        // A crash before the write applied is finished by HaltedFeatureRepair.observe.
        let world2 = try await DraftWorld()
        // Write 1: create Feature Issue, Write 2: comment. Crash before write 3 (the feature-dod write).
        let crashed = crashing(try world2.context(night: "2026-10-01"), boards: world2.rig.boards, afterApplying: 2)
        await #expect(throws: SimulatedCrash.self) { _ = try await world2.rig.selection.selectAndAuthor(crashed) }
        _ = try world2.halt()
        let descBefore = try await world2.featureDescription()
        #expect(!descBefore.contains(FeatureAuthoringProse.start), "crashed before feature-dod write applied")

        try await HaltedFeatureRepair.observe(context: try world2.context(night: "2026-10-01"))
        let descAfter = try await world2.featureDescription()
        #expect(descAfter.contains(FeatureAuthoringProse.start), "finished by observe")
        #expect(descAfter.contains("## Definition of done"))
        #expect(descAfter.contains("- [ ] The Feature is done. (resolvable/story)"))
    }

    @Test("Operator edits Feature Definition of Done: accepted plan and card hold edited clauses (c3, c4)")
    func operatorEditsFeatureDefinitionOfDone() async throws {
        let world = try await DraftWorld()
        _ = try await world.haltTheFeature()
        let issue = try world.issueID()

        let descBefore = try await world.featureDescription()
        #expect(descBefore.contains("- [ ] The Feature is done. (resolvable/story)"))

        // Repair child drafts so children are valid
        _ = try await world.repairTheOverlap()

        // The Operator edits the Feature Card's Definition of Done: one clause reworded, one added
        let oldClauses = "- [ ] The Feature is done. (resolvable/story)"
        let newClauses = """
        - [ ] The Feature is completely done. (resolvable/story)
        - [ ] An extra clause is done. (resolvable/story)
        """
        try await world.operatorEditsFeature(replacing: oldClauses, with: newClauses)
        try await world.operatorMoves(issue, to: .todo)

        try await world.runAuthorAct(night: "2026-10-02")

        // 1. Accepted plan's featureClauses holds edited clauses, not checkpoint's:
        let plans = try world.journal.events(ofType: .featureAuthoringAccepted).compactMap { record in
            if case .featureAuthoringAccepted(let payload) = record.event { return payload }
            return nil
        }
        let plan = try #require(plans.first)
        #expect(plan.featureClauses.count == 2)
        #expect(plan.featureClauses.map(\.text) == ["The Feature is completely done.", "An extra clause is done."])

        // 2. The accepted Feature Card holds the edited clauses:
        let descAfter = try await world.featureDescription()
        #expect(descAfter.contains("The Feature is completely done."))
        #expect(descAfter.contains("An extra clause is done."))
        #expect(!descAfter.contains("The Feature is done. ("))
        #expect(descAfter.contains("<!-- yh:clause:c1 -->"))
        #expect(descAfter.contains("<!-- yh:clause:c2 -->"))

        // 3. No outbox entry aborted as input-invalid:
        let aborted = try world.journal.outboxEntries(forIssue: issue.rawValue).filter { $0.state == .aborted }
        #expect(aborted.isEmpty, "no outbox entry was aborted")

        // 4. No "did not re-author" comment posted:
        let comments = await world.comments(on: issue)
        #expect(!comments.contains { $0.contains("did not re-author") })
    }

    @Test("Feature Card Definition of Done edited between validation and acceptance defers and accepts nothing (c5)")
    func featureEditedBeforeAcceptance() async throws {
        let world = try await DraftWorld()
        let halted = try await world.haltTheFeature()
        try await world.repairTheOverlap()
        let context = try world.context(night: "2026-10-02")
        try await HaltedFeatureRepair.observe(context: context)
        let checkpoint = try #require(try world.journal.authoringHaltCheckpoint(haltID: halted.id))
        let snapshot = try #require(
            try await HaltRepairSnapshot.take(halt: halted, checkpoint: checkpoint, context: context)
        )
        #expect(snapshot.problems.isEmpty)
        let plan = AuthoringPlan(
            writes: [],
            record: FeatureAuthoringAcceptedPayload(
                name: "FEAT-1", groupKey: "authoring:test", featureKey: "feature:test", nightID: context.night.id,
                cards: [], adoptions: [], bases: []
            ),
            reusedFeatureIssue: try world.issueID(), repairSnapshot: snapshot
        )

        // The Operator edits the Feature Card's Definition of Done after validation:
        try await world.operatorEditsFeature(
            replacing: "The Feature is done.", with: "The Feature is modified after validation."
        )

        let outcome = try await HaltedFeatureRepair.revalidateBeforeAcceptance(plan, context: context)
        #expect(outcome == .authoringPending)
        #expect(try world.steps().contains("deferred"))
        #expect(try tableRowCount(world.journal, table: "cycle") == 0)
        #expect(try await world.featureDescription().contains("The Feature is modified after validation."))
        let comments = await world.comments(on: try world.issueID())
        #expect(comments.contains { $0.contains("changed while it was being validated") })
    }

    enum FeatureDODInvalidEdit: Sendable {
        case deletedRegion
        case notAClauseLine
    }

    @Test("Deleted Feature DoD region or invalid clause line is invalid repair, names card and restore (c6)",
          arguments: [FeatureDODInvalidEdit.deletedRegion, FeatureDODInvalidEdit.notAClauseLine])
    func invalidFeatureDefinitionOfDone(edit: FeatureDODInvalidEdit) async throws {
        let world = try await DraftWorld()
        let halted = try await world.haltTheFeature()
        let issue = try world.issueID()
        try await world.repairTheOverlap()

        switch edit {
        case .deletedRegion:
            try await world.operatorEditsFeature(description: ManagedBlockFence.initialDescription(rendered: ""))
        case .notAClauseLine:
            try await world.operatorEditsFeature(
                replacing: "- [ ] The Feature is done.", with: "This is freeform prose not a checklist"
            )
        }

        try await world.runAuthorAct(night: "2026-10-02")

        let currentHalt = try #require(try world.journal.authoringHalts(feature: world.feature).last)
        #expect(currentHalt.id == halted.id)
        #expect(currentHalt.state != .cleared, "Feature stays halted")
        #expect(world.rig.drafting.callCount == 1, "no model call")
        #expect(try world.journal.authoringFaultCount(feature: world.feature).count == Int.zero, "no authoring fault")

        let diagnostic = try #require(try world.journal.authoringHaltCheckpoint(haltID: halted.id)?.repairDiagnostic)
        #expect(diagnostic.contains("FEAT-1"), "diagnostic names Feature Card")

        switch edit {
        case .deletedRegion:
            #expect(diagnostic.contains("restore the delimiters"))
        case .notAClauseLine:
            #expect(diagnostic.contains("write `- [ ] text (citation)`"))
        }

        let comments = await world.comments(on: issue)
        let invalidComment = try #require(comments.last { $0.contains("is not accepted") })
        #expect(invalidComment.contains("FEAT-1"))
        switch edit {
        case .deletedRegion:
            #expect(invalidComment.contains("restore the delimiters"))
        case .notAClauseLine:
            #expect(invalidComment.contains("write `- [ ] text (citation)`"))
        }
    }
}

private extension DraftWorld {
    func state(of issue: BoardObjectID) async throws -> BoardObjectID? { await writing.issue(issue)?.workflowState }
}
