import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
import Journal
import Repositories
import Testing

// roadmap P8.2: the Readiness Check's reconciliation of the board's copy of a Card's Managed Block —
// Divergence, an Operator edit voiding a Transcription Block's stamp, minting an untagged clause, and
// tagged clause edits. Fixture helpers live in ReadinessCheckTests.swift.

@Test("A stale Transcription Block diverges the Card, incrementing and resetting the counter")
func staleBlockDiverges() async throws {
    let scenario = try await makeReadinessScenario()
    defer { cleanup(scenario) }
    try scenario.journal.recordArchitecturalBrief(cardID: scenario.cardOne, prose: "A brief.")
    try scenario.journal.insertClause(JournalStore.NewClause(
        cid: "c1", issueID: scenario.issueOne, level: "card", text: "A clause",
        locationID: "resolvable/story", provenance: "Author-supplied", citationProvenance: "Author-supplied"
    ))
    try scenario.journal.recordTranscriptionBlocks(cardID: scenario.cardOne, [
        TranscriptionBlock(
            repository: "backend", paths: ["a.swift"], mainlineCommit: "deadbeef", content: "old content",
            contentHash: ManagedBlockFence.sha256("old content"), authorSupplied: false
        )
    ])
    let readiness = ReadinessCheck(
        provenance: FakeProvenanceTester(verdicts: ["backend": .stale(changedPaths: ["a.swift"])]),
        citations: FakeCitationResolver(resolvable: ["resolvable/story"])
    )

    try await runReadinessAct(scenario, readiness: readiness)

    let card = try #require(try scenario.journal.card(issueID: scenario.issueOne))
    #expect(card.state == .waitingOnYou)
    #expect(card.waitingReason == .divergence)
    let scope = try await BoardStateScope.resolve(using: scenario.boards.provisioning)
    let posted = try #require(await scenario.boards.writing.issue(BoardObjectID(rawValue: scenario.issueOne)))
    #expect(posted.workflowState == (try scope.id(for: .waitingOnYou)))
    #expect(posted.assignee == nil)
    #expect(try scenario.journal.consecutiveDivergences(cardID: scenario.cardOne) == 1)

    let diverged = try scenario.journal.events(ofType: .cardDiverged)
    guard case .cardDiverged(_, _, let repository, let changedPaths) = diverged[0].event else {
        Issue.record("expected cardDiverged")
        return
    }
    #expect(repository == "backend")
    #expect(changedPaths == ["a.swift"])

    // A Diverged Card leaves the runnable lane (it is Waiting on You, not Todo), so a second stale
    // pass is exercised by calling `evaluate` directly against the still-recorded stale block, the way
    // a later phase's re-check after the Operator resolves the question would.
    guard case .diverged = try await directEvaluate(scenario, cardID: scenario.cardOne, readiness: readiness) else {
        Issue.record("expected diverged")
        return
    }
    #expect(try scenario.journal.consecutiveDivergences(cardID: scenario.cardOne) == 2)

    // A clean pass resets it to 0.
    let cleanReadiness = ReadinessCheck(
        provenance: FakeProvenanceTester(), citations: FakeCitationResolver(resolvable: ["resolvable/story"])
    )
    _ = try await directEvaluate(scenario, cardID: scenario.cardOne, readiness: cleanReadiness)
    #expect(try scenario.journal.consecutiveDivergences(cardID: scenario.cardOne) == 0)
}

@Test("An Operator edit inside a Transcription Block voids its stamp, without a Divergence, and dispatches")
func operatorEditVoidsStamp() async throws {
    let scenario = try await makeReadinessScenario()
    defer { cleanup(scenario) }
    try scenario.journal.recordArchitecturalBrief(cardID: scenario.cardOne, prose: "A brief.")
    try scenario.journal.insertClause(JournalStore.NewClause(
        cid: "c1", issueID: scenario.issueOne, level: "card", text: "A clause",
        locationID: "resolvable/story", provenance: "Author-supplied", citationProvenance: "Author-supplied"
    ))
    let originalBlock = TranscriptionBlock(
        repository: "backend", paths: ["a.swift"], mainlineCommit: "deadbeef", content: "original content",
        contentHash: ManagedBlockFence.sha256("original content"), authorSupplied: false
    )
    try scenario.journal.recordTranscriptionBlocks(cardID: scenario.cardOne, [originalBlock])

    let clause = DoDClause(
        cid: "c1", text: "A clause", citation: "resolvable/story", citationProvenance: "Author-supplied"
    )
    let editedBlock = TranscriptionBlock(
        repository: "backend", paths: ["a.swift"], mainlineCommit: "deadbeef", content: "EDITED content",
        contentHash: ManagedBlockFence.sha256("EDITED content"), authorSupplied: false
    )
    let block = CardManagedBlock(
        kind: "card", repository: "backend", state: .todo, lanePosition: 1, laneLength: 2,
        brief: ArchitecturalBrief(prose: "A brief.", transcriptions: [editedBlock]),
        definitionOfDone: [clause], attempts: []
    )
    await scenario.boards.writing.seed(issue: scenario.issueOne, description: fenced(block: block.render()))

    // The fake would call this repository stale, but the block is now Operator-supplied and must not
    // be tested as stale.
    let readiness = ReadinessCheck(
        provenance: FakeProvenanceTester(verdicts: ["backend": .stale(changedPaths: ["a.swift"])]),
        citations: FakeCitationResolver(resolvable: ["resolvable/story"])
    )

    try await runReadinessAct(
        scenario, readiness: readiness,
        updatedObjects: [object(scenario.issueOne, state: stateTodo, description: fenced(block: block.render()))]
    )

    let voided = try scenario.journal.events(ofType: .transcriptionStampVoided)
    #expect(voided.count == 1)

    let rows = try scenario.journal.transcriptionBlocks(cardID: scenario.cardOne)
    #expect(rows[0].authorSupplied == true)
    #expect(rows[0].mainlineCommit == nil)

    #expect(try scenario.journal.events(ofType: .cardDiverged).isEmpty)
    let card = try #require(try scenario.journal.card(issueID: scenario.issueOne))
    #expect(card.state == .todo)

    let passedIssueIDs = try scenario.journal.events(ofType: .readinessCheckPassed).map { event -> String in
        if case .readinessCheckPassed(_, let issueID) = event.event { return issueID }
        return ""
    }
    #expect(passedIssueIDs.contains(scenario.issueOne))
    #expect(scenario.recorder.seen.map(\.issueID).contains(scenario.issueOne))
}

@Test("An untagged clause on the board mints a synthetic clause id and rewrites the Managed Block")
func untaggedClauseIsMinted() async throws {
    let scenario = try await makeReadinessScenario()
    defer { cleanup(scenario) }
    try scenario.journal.recordArchitecturalBrief(cardID: scenario.cardOne, prose: "A brief.")

    let block = """
    **Kind:** `card`

    ### Architectural Brief
    A brief.

    ### Definition of Done
    - [ ] An untagged human clause (resolvable/story)

    ### Attempts
    _No Attempt yet._
    """
    await scenario.boards.writing.seed(issue: scenario.issueOne, description: fenced(block: block))

    let readiness = ReadinessCheck(
        provenance: FakeProvenanceTester(), citations: FakeCitationResolver(resolvable: ["resolvable/story"])
    )

    try await runReadinessAct(
        scenario, readiness: readiness,
        updatedObjects: [object(scenario.issueOne, state: stateTodo, description: fenced(block: block))]
    )

    let minted = try scenario.journal.events(ofType: .clauseMinted)
    #expect(minted.count == 1)
    guard case .clauseMinted(let issueID, let cid) = minted[0].event else {
        Issue.record("expected clauseMinted")
        return
    }
    #expect(issueID == scenario.issueOne)
    #expect(cid == "c1")

    let clauses = try scenario.journal.clauses(issueID: scenario.issueOne)
    #expect(clauses.count == 1)
    #expect(clauses[0].provenance == "Author-supplied")

    let posted = await scenario.boards.writing.issue(BoardObjectID(rawValue: scenario.issueOne))?.description
    #expect(posted?.contains("<!-- yh:clause:c1 -->") == true)
}

@Test("A tagged clause's text and citation edits, and its deletion, are reconciled by identity")
func taggedClauseEditsReconcile() async throws {
    let scenario = try await makeReadinessScenario()
    defer { cleanup(scenario) }
    try scenario.journal.recordArchitecturalBrief(cardID: scenario.cardOne, prose: "A brief.")
    try scenario.journal.insertClause(JournalStore.NewClause(
        cid: "c1", issueID: scenario.issueOne, level: "card", text: "Original text",
        locationID: "resolvable/story", provenance: "machine-found", citationProvenance: "machine-found"
    ))
    try scenario.journal.insertClause(JournalStore.NewClause(
        cid: "c2", issueID: scenario.issueOne, level: "card", text: "Second clause",
        locationID: "resolvable/story", provenance: "machine-found", citationProvenance: "machine-found"
    ))

    let block = """
    **Kind:** `card`

    ### Architectural Brief
    A brief.

    ### Definition of Done
    - [ ] <!-- yh:clause:c1 --> Edited text (resolvable/other)

    ### Attempts
    _No Attempt yet._
    """
    await scenario.boards.writing.seed(issue: scenario.issueOne, description: fenced(block: block))

    let readiness = ReadinessCheck(
        provenance: FakeProvenanceTester(),
        citations: FakeCitationResolver(resolvable: ["resolvable/story", "resolvable/other"])
    )

    try await runReadinessAct(
        scenario, readiness: readiness,
        updatedObjects: [object(scenario.issueOne, state: stateTodo, description: fenced(block: block))]
    )

    let invalidatedEvents = try scenario.journal.events(ofType: .clauseInvalidated)
    let causes = Set(invalidatedEvents.compactMap { event -> String? in
        if case .clauseInvalidated(_, "c1", let cause) = event.event { return cause }
        return nil
    })
    #expect(causes.contains("text_edited"))
    #expect(causes.contains("citation_edited"))

    let deleted = try scenario.journal.events(ofType: .clauseDeleted)
    #expect(deleted.contains { if case .clauseDeleted(_, "c2") = $0.event { return true } else { return false } })

    // clauses(issueID:) excludes deleted rows, so c1's still-current state is what's left.
    let clauses = try scenario.journal.clauses(issueID: scenario.issueOne)
    #expect(clauses.count == 1)
    #expect(clauses[0].cid == "c1")
    // The clause's identity is preserved: an edit invalidates it (its stored text is the Journal's, not
    // the board's) but only the citation's location_id is actually updated on a citation edit.
    #expect(clauses[0].text == "Original text")
    #expect(clauses[0].locationID == "resolvable/other")
    #expect(clauses[0].invalidated == true)
    #expect(clauses[0].citationProvenance == "Author-supplied")
}

@Test("An edit outside the Managed Block's structured fields voids nothing")
func proseEditVoidsNothing() async throws {
    let scenario = try await makeReadinessScenario()
    defer { cleanup(scenario) }
    try scenario.journal.recordArchitecturalBrief(cardID: scenario.cardOne, prose: "Original prose.")
    try scenario.journal.insertClause(JournalStore.NewClause(
        cid: "c1", issueID: scenario.issueOne, level: "card", text: "A clause",
        locationID: "resolvable/story", provenance: "Author-supplied", citationProvenance: "Author-supplied"
    ))

    let brief = ArchitecturalBrief(prose: "Edited prose.", transcriptions: [])
    let clause = DoDClause(
        cid: "c1", text: "A clause", citation: "resolvable/story", citationProvenance: "Author-supplied"
    )
    let block = CardManagedBlock(
        kind: "card", repository: "backend", state: .todo, lanePosition: 1, laneLength: 2,
        brief: brief, definitionOfDone: [clause], attempts: []
    )
    await scenario.boards.writing.seed(issue: scenario.issueOne, description: fenced(block: block.render()))

    let readiness = ReadinessCheck(
        provenance: FakeProvenanceTester(), citations: FakeCitationResolver(resolvable: ["resolvable/story"])
    )

    try await runReadinessAct(
        scenario, readiness: readiness,
        updatedObjects: [object(scenario.issueOne, state: stateTodo, description: fenced(block: block.render()))]
    )

    #expect(try scenario.journal.events(ofType: .transcriptionStampVoided).isEmpty)
    #expect(try scenario.journal.events(ofType: .clauseInvalidated).isEmpty)
    #expect(try scenario.journal.architecturalBriefProse(cardID: scenario.cardOne) == "Edited prose.")
}
