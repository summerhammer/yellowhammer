import Domain
import Foundation
import Testing

@testable import Engine
@testable import Journal

// board-projection/maintain-the-managed-block, field ownership (roadmap P22.4): the Board owns a Card's scope,
// Architectural Brief and Definition of Done even inside the Managed Block's markers, so a rewrite imports
// what the description now holds before it renders; an edit that cannot be read is kept as written and said
// so once; and the Journal-owned output (Attempts, roll-up) is regenerated, never read back as a result.

private let authoredBrief = "Add the endpoint."
private let authoredBriefInBlock = ArchitecturalBrief(prose: authoredBrief, transcriptions: [])

private struct BlockRig {
    let journal: JournalStore
    let board: FakeWritingBoard
    let issue: BoardObjectID
    let cardID: Int64
    let runID: RunID
    let maintenance: ManagedBlockMaintenance

    func card() throws -> CardRecord { try journal.card(id: cardID) }

    func description() async throws -> String {
        try #require(await board.issue(issue)?.description)
    }

    /// What the Journal now holds for the brief, so the next render starts from it.
    func maintain() async throws -> ManagedBlockMaintenance.Outcome {
        try await maintenance.maintain(card: try card(), brief: authoredBriefInBlock)
    }

    /// Any change to what the Journal renders, so the next rewrite is not skipped as unchanged.
    func changeJournalOutput() throws {
        _ = try journal.transitionCard(
            cardID: cardID, to: .blocked, blockReason: .checkFailure, runID: runID, act: .build, nightID: nil,
            now: outboxEpoch
        )
    }

    /// The Operator edits the description by hand.
    func operatorEdits(_ transform: (String) -> String) async throws {
        await board.edit(issue, description: transform(try await description()))
    }
}

/// A Card whose Managed Block Yellowhammer has written once, so a later edit has a baseline to differ from.
private func makeBlockRig(_ journal: JournalStore) async throws -> BlockRig {
    let board = FakeWritingBoard()
    let issue = await board.seed(
        issue: "issue-1", description: ManagedBlockFence.initialDescription(rendered: "") + "\n\nWhat to build."
    )
    let cardID = try insertFixtureCard(journal, issueID: "issue-1")
    try journal.recordArchitecturalBrief(cardID: cardID, prose: authoredBrief)
    try journal.insertClause(JournalStore.NewClause(
        cid: "c1", issueID: "issue-1", level: "card", text: "The endpoint answers 200.",
        locationID: "resolvable/story", provenance: "machine-found", citationProvenance: "machine-found"
    ))
    let runID = RunID()
    let outbox = try outbox(journal, board: board, runID: runID)
    _ = try journal.claimCardLease(cardID: cardID, runID: runID, now: outboxEpoch)
    let rig = BlockRig(
        journal: journal, board: board, issue: issue, cardID: cardID, runID: runID,
        maintenance: ManagedBlockMaintenance(journal: journal, outbox: outbox)
    )
    guard case .posted(_, let block, _) = try await rig.maintain(), case .applied = block.outcome else {
        Issue.record("expected the first rewrite to be applied")
        return rig
    }
    return rig
}

@Suite("Managed Block input preservation")
struct ManagedBlockInputPreservationTests {
    @Test("An Operator's brief edit inside the markers survives a rewrite that starts from the authored brief")
    func briefEditSurvivesRender() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let rig = try await makeBlockRig(journal)
        try await rig.operatorEdits {
            $0.replacingOccurrences(of: authoredBrief, with: "Add the endpoint, behind the feature flag.")
        }
        try rig.changeJournalOutput()

        // The caller still holds the authored brief: it is the rewrite that must not write it back.
        let outcome = try await rig.maintain()

        guard case .posted(_, let block, _) = outcome, case .applied = block.outcome else {
            Issue.record("expected the re-rendered block to be applied, got \(outcome)")
            return
        }
        let description = try await rig.description()
        #expect(description.contains("Add the endpoint, behind the feature flag."))
        #expect(!description.contains("\n\(authoredBrief)\n"))
        #expect(try journal.architecturalBriefProse(cardID: rig.cardID) == "Add the endpoint, behind the feature flag.")
        // The output moved with the Journal, and the text outside the markers is byte-identical.
        #expect(description.contains("Blocked"))
        #expect(description.hasSuffix("\n\nWhat to build."))
        #expect(try journal.events(ofType: .managedBlockInputImported).count == 1)
    }

    @Test("An Operator's scope and Definition of Done edits survive a rewrite")
    func scopeAndDefinitionOfDoneEditsSurvive() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let rig = try await makeBlockRig(journal)
        try await rig.operatorEdits {
            $0.replacingOccurrences(of: "The endpoint answers 200.", with: "The endpoint answers 201.")
                .replacingOccurrences(of: "**Scope:** _none declared_", with: "**Scope:** `src/api`")
        }
        try rig.changeJournalOutput()

        _ = try await rig.maintain()

        let description = try await rig.description()
        #expect(description.contains("The endpoint answers 201."))
        #expect(description.contains("**Scope:** `src/api`"))
        #expect(try journal.declaredScope(cardID: rig.cardID) == ["src/api"])
        let clause = try #require(try journal.clauses(issueID: "issue-1").first)
        #expect(clause.text == "The endpoint answers 201." && clause.cid == "c1")
    }

    @Test("A Definition of Done edit that cannot be read is kept as written, with one comment per revision")
    func invalidDefinitionOfDoneIsRetained() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let rig = try await makeBlockRig(journal)
        try await rig.operatorEdits {
            $0.replacingOccurrences(of: "### Definition of Done\n", with: "### Definition of Done\nAsk legal first\n")
        }
        let edited = try await rig.description()
        try rig.changeJournalOutput()

        let first = try await rig.maintain()

        guard case .posted(_, let block, _) = first, case .aborted = block.outcome else {
            Issue.record("expected the rewrite to be aborted, got \(first)")
            return
        }
        #expect(try await rig.description() == edited)
        #expect(try journal.clauses(issueID: "issue-1").map(\.text) == ["The endpoint answers 200."])
        #expect(await rig.board.comments.count == 1)
        #expect(try #require(await rig.board.comments.first).body.contains("Ask legal first"))
        #expect(try journal.events(ofType: .managedBlockInputInvalid).count == 1)

        // The same revision of the block is not announced twice.
        try await rig.board.edit(rig.issue, description: edited)
        _ = try journal.transitionCard(
            cardID: rig.cardID, to: .todo, runID: rig.runID, act: .build, nightID: nil, now: outboxEpoch
        )
        _ = try await rig.maintain()
        #expect(try await rig.description() == edited)
        #expect(await rig.board.comments.count == 1)
    }

    @Test("A Definition of Done section the Operator deleted is kept as written, not read as every clause removed")
    func missingDefinitionOfDoneSectionIsInvalid() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let rig = try await makeBlockRig(journal)
        try await rig.operatorEdits { description in
            let lines = description.components(separatedBy: "\n")
            return lines.filter { !$0.contains("yh:clause:c1") && $0 != "### Definition of Done" }
                .joined(separator: "\n")
        }
        let edited = try await rig.description()
        try rig.changeJournalOutput()

        _ = try await rig.maintain()

        #expect(try await rig.description() == edited)
        #expect(try journal.clauses(issueID: "issue-1").count == 1)
    }

    @Test("Editing the Attempts section changes no recorded result, and the next rewrite regenerates it")
    func outputOnlyEditsChangeNothing() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let rig = try await makeBlockRig(journal)
        let route = try #require(Route(cli: "claude", model: "opus", effort: "high"))
        let attempt = try journal.recordAttempt(cardID: rig.cardID, route: route, runID: rig.runID, now: outboxEpoch)
        try journal.append(
            .checkRan(
                cardID: rig.cardID, issueID: "issue-1", attemptID: attempt.id, result: .failed, exitStatus: 1,
                output: nil, judgedCommit: nil
            ),
            runID: rig.runID, now: outboxEpoch
        )
        _ = try await rig.maintain()
        #expect(try await rig.description().contains("- Check: failed"))
        let historyBefore = try journal.attemptHistory(cardID: rig.cardID)
        let checksBefore = try journal.checkRuns(cardID: rig.cardID)

        try await rig.operatorEdits { $0.replacingOccurrences(of: "- Check: failed", with: "- Check: passed") }
        try rig.changeJournalOutput()
        _ = try await rig.maintain()

        #expect(try journal.attemptHistory(cardID: rig.cardID).attempts == historyBefore.attempts)
        #expect(try journal.checkRuns(cardID: rig.cardID) == checksBefore)
        let description = try await rig.description()
        #expect(description.contains("- Check: failed") && !description.contains("- Check: passed"))
        #expect(try journal.events(ofType: .managedBlockInputImported).isEmpty)
    }

    @Test("A block nobody edited is not rewritten again")
    func unchangedBlockIsNotReposted() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let rig = try await makeBlockRig(journal)
        let updates = await rig.board.updateCalls

        guard case .skipped = try await rig.maintain() else {
            Issue.record("expected the unchanged block to be skipped")
            return
        }

        #expect(await rig.board.updateCalls == updates)
    }

    @Test("Any Act's Delta Read imports the Operator's edit, without writing to the board")
    func authorActReadImportsTheEdit() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let rig = try await makeBlockRig(journal)
        try await rig.operatorEdits { $0.replacingOccurrences(of: authoredBrief, with: "Add it behind a flag.") }
        let edited = try await rig.description()
        let updates = await rig.board.updateCalls
        let board = FakeReadingBoard([page(objects: [
            object("issue-1", state: stateTodo, description: edited, updatedAt: 50)
        ])])
        let read = DeltaRead(
            journal: journal, board: board, runID: rig.runID, act: .author, horizon: { .distantFuture }
        )

        guard case .read(let report) = try await read.perform() else {
            Issue.record("expected a read")
            return
        }

        #expect(report.cardChanges.first?.importedInputs == ["brief"])
        #expect(try journal.architecturalBriefProse(cardID: rig.cardID) == "Add it behind a flag.")
        #expect(await rig.board.updateCalls == updates)
    }

    @Test("Feature brief and Definition of Done edited on the board survive re-authoring")
    func featureRegionEditSurvivesReauthoring() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let board = FakeWritingBoard()
        let issue = await board.seed(
            issue: "feature-1", description: ManagedBlockFence.initialDescription(rendered: "") + "\n\nOriginal prose."
        )
        let runID = RunID()
        let outbox = try outbox(journal, board: board, runID: runID)
        let first = try await outbox.post(OutboxWrite(
            key: "feature:F:0:description",
            write: .rewriteFeatureAuthoring(issue: issue, prose: "Brief.\n\n- [ ] Clause one")
        ))
        guard case .applied = first.outcome else {
            Issue.record("expected the first authoring to be applied, got \(first.outcome)")
            return
        }
        let current = try #require(await board.issue(issue)?.description)
        await board.edit(
            issue, description: current.replacingOccurrences(of: "Clause one", with: "Clause one, as I want it")
        )
        let edited = try #require(await board.issue(issue)?.description)

        let second = try await outbox.post(OutboxWrite(
            key: "feature:F:1:description",
            write: .rewriteFeatureAuthoring(issue: issue, prose: "Brief, again.\n\n- [ ] Clause one")
        ))

        guard case .aborted = second.outcome else {
            Issue.record("expected the re-authoring to be set aside, got \(second.outcome)")
            return
        }
        #expect(await board.issue(issue)?.description == edited)
        #expect(await board.comments.count == 1)
    }

    @Test("An unedited Feature region is replaced by re-authoring, as before")
    func uneditedFeatureRegionIsReplaced() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let board = FakeWritingBoard()
        let issue = await board.seed(
            issue: "feature-1", description: ManagedBlockFence.initialDescription(rendered: "")
        )
        let outbox = try outbox(journal, board: board)
        _ = try await outbox.post(OutboxWrite(
            key: "feature:F:0:description", write: .rewriteFeatureAuthoring(issue: issue, prose: "Brief one.")
        ))

        let second = try await outbox.post(OutboxWrite(
            key: "feature:F:1:description", write: .rewriteFeatureAuthoring(issue: issue, prose: "Brief two.")
        ))

        guard case .applied = second.outcome else {
            Issue.record("expected applied, got \(second.outcome)")
            return
        }
        let description = try #require(await board.issue(issue)?.description)
        #expect(description.contains("Brief two.") && !description.contains("Brief one."))
    }
}
