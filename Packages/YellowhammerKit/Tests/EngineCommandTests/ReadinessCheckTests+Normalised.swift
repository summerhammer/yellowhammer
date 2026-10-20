import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
import Journal
import Repositories
import Testing

// Issue #433: Linear parses the Markdown of a Card's description and re-serialises it. The Readiness
// Check must tell that rewrite apart from an Operator edit. Each scenario hand-applies the rewrites seen
// in production to a block Yellowhammer rendered itself, and fixture helpers live in
// ReadinessCheckTests.swift.

/// A Transcription Block's content as Yellowhammer wrote it: a bracket, a domain-like token, an
/// indented code block and a dash list.
private let ourContent = """
Stored [bracket] and night.id here.

    let x = 1
    let y = 2

- first
- second
"""

/// The same content as Linear hands it back: escaped brackets, an autolink, a fenced and dedented code
/// block with blank lines around it, and asterisk bullets.
private let linearContent = #"""
Stored \[bracket\] and [night.id](<http://night.id>) here.

```
let x = 1
let y = 2
```

* first
* second
"""#

private let ourBriefProse = "A brief.\n### Implementation\nStored [bracket] and night.id here.\n\n- first\n- second"
private let linearBriefProse = #"""
A brief.
### Implementation
Stored \[bracket\] and [night.id](<http://night.id>) here.

* first
* second
"""#

private let ourClauseText = "Offsets are [22:19, 22:34] and fixture.open() works"
private let linearClauseText = #"Offsets are \[22:19, 22:34\] and [fixture.open](<http://fixture.open>)() works"#

/// Records, in the scenario's Journal, the Transcription Block, brief and clause Yellowhammer wrote, and
/// returns the Managed Block it rendered for them.
private func seedRenderedCard(_ scenario: ReadinessScenario) throws -> String {
    try scenario.journal.recordArchitecturalBrief(cardID: scenario.cardOne, prose: ourBriefProse)
    try scenario.journal.insertClause(JournalStore.NewClause(
        cid: "c1", issueID: scenario.issueOne, level: "card", text: ourClauseText,
        locationID: "resolvable/story", provenance: "Author-supplied", citationProvenance: "Author-supplied"
    ))
    let block = TranscriptionBlock(
        repository: "backend", paths: ["a.swift"], mainlineCommit: "deadbeef", content: ourContent,
        contentHash: ManagedBlockFence.sha256(ourContent), authorSupplied: false
    )
    try scenario.journal.recordTranscriptionBlocks(cardID: scenario.cardOne, [block])
    let clause = DoDClause(
        cid: "c1", text: ourClauseText, citation: "resolvable/story", citationProvenance: "Author-supplied"
    )
    return CardManagedBlock(
        kind: "card", repository: "backend", state: .todo, lanePosition: 1, laneLength: 2,
        brief: ArchitecturalBrief(prose: ourBriefProse, transcriptions: [block]),
        definitionOfDone: [clause], attempts: []
    ).render()
}

/// The description Linear would hand back for `rendered`: the content and clause text swapped for their
/// Linear forms, a blank line added after each heading, and the managed end marker indented.
private func linearDescription(
    of rendered: String, content: String = linearContent, clauseText: String = linearClauseText
) -> String {
    let block = rendered
        .replacingOccurrences(of: ourContent, with: content)
        .replacingOccurrences(of: ourBriefProse, with: linearBriefProse)
        .replacingOccurrences(of: ourClauseText, with: clauseText)
        .replacingOccurrences(of: "### Architectural Brief\n", with: "### Architectural Brief\n\n")
        .replacingOccurrences(of: "### Definition of Done\n", with: "### Definition of Done\n\n")
    return fenced(block: block)
        .replacingOccurrences(of: "\n<!-- yh:managed:end -->", with: "\n  <!-- yh:managed:end -->")
}

@Test("A Linear-normalised rewrite of our own block voids and invalidates nothing, and the Journal keeps its copy")
func linearNormalisedRewriteIsNotAnEdit() async throws {
    let scenario = try await makeReadinessScenario()
    defer { cleanup(scenario) }
    let rendered = try seedRenderedCard(scenario)
    let description = linearDescription(of: rendered)
    // The fixture really is a rewrite: the board's copy is not byte-identical to what we rendered.
    #expect(description != fenced(block: rendered))
    await scenario.boards.writing.seed(issue: scenario.issueOne, description: description)
    let readiness = ReadinessCheck(
        provenance: FakeProvenanceTester(verdicts: ["backend": .clean]),
        citations: FakeCitationResolver(resolvable: ["resolvable/story"])
    )

    try await runReadinessAct(
        scenario, readiness: readiness,
        updatedObjects: [object(scenario.issueOne, state: stateTodo, description: description)]
    )

    #expect(try scenario.journal.events(ofType: .transcriptionStampVoided).isEmpty)
    #expect(try scenario.journal.events(ofType: .clauseInvalidated).isEmpty)
    let rows = try scenario.journal.transcriptionBlocks(cardID: scenario.cardOne)
    #expect(rows[0].content == ourContent)
    #expect(rows[0].contentHash == ManagedBlockFence.sha256(ourContent))
    #expect(rows[0].authorSupplied == false)
    #expect(rows[0].mainlineCommit == "deadbeef")
    #expect(try scenario.journal.architecturalBriefProse(cardID: scenario.cardOne) == ourBriefProse)
    #expect(try scenario.journal.clauses(issueID: scenario.issueOne)[0].text == ourClauseText)
    let passed = try scenario.journal.events(ofType: .readinessCheckPassed).map { event -> String in
        if case .readinessCheckPassed(_, let issueID) = event.event { return issueID }
        return ""
    }
    #expect(passed.contains(scenario.issueOne))
}

@Test("Text edited inside a Linear-normalised block voids nothing and changes nothing in the Journal")
func operatorEditInsideNormalisedBlockChangesNothing() async throws {
    let scenario = try await makeReadinessScenario()
    defer { cleanup(scenario) }
    // The Card carries a block's reference only, and the board's text inside a block is never read back:
    // an edit to the reference line, and a line added where legacy content used to sit, are both ignored.
    let edited = linearDescription(of: try seedRenderedCard(scenario))
        .replacingOccurrences(of: "Contract: `backend`", with: "EDITED BY THE OPERATOR")
        .replacingOccurrences(
            of: "<!-- yh:transcription:end -->", with: "let y = 3\n<!-- yh:transcription:end -->"
        )
    #expect(edited.contains("EDITED BY THE OPERATOR") && edited.contains("let y = 3"))
    await scenario.boards.writing.seed(issue: scenario.issueOne, description: edited)
    let readiness = ReadinessCheck(
        provenance: FakeProvenanceTester(verdicts: ["backend": .clean]),
        citations: FakeCitationResolver(resolvable: ["resolvable/story"])
    )

    try await runReadinessAct(
        scenario, readiness: readiness,
        updatedObjects: [object(scenario.issueOne, state: stateTodo, description: edited)]
    )

    #expect(try scenario.journal.events(ofType: .transcriptionStampVoided).isEmpty)
    let rows = try scenario.journal.transcriptionBlocks(cardID: scenario.cardOne)
    #expect(rows[0].content == ourContent)
    #expect(rows[0].contentHash == ManagedBlockFence.sha256(ourContent))
    #expect(rows[0].authorSupplied == false)
    #expect(rows[0].mainlineCommit == "deadbeef")
    #expect(try scenario.journal.events(ofType: .clauseInvalidated).isEmpty)
}

@Test("A real clause text edit with escaped brackets present still invalidates the clause as text_edited")
func clauseEditWithEscapedBracketsInvalidates() async throws {
    let scenario = try await makeReadinessScenario()
    defer { cleanup(scenario) }
    let editedClause = linearClauseText.replacingOccurrences(of: "22:34", with: "22:35")
    let description = linearDescription(of: try seedRenderedCard(scenario), clauseText: editedClause)
    await scenario.boards.writing.seed(issue: scenario.issueOne, description: description)
    let readiness = ReadinessCheck(
        provenance: FakeProvenanceTester(verdicts: ["backend": .clean]),
        citations: FakeCitationResolver(resolvable: ["resolvable/story"])
    )

    try await runReadinessAct(
        scenario, readiness: readiness,
        updatedObjects: [object(scenario.issueOne, state: stateTodo, description: description)]
    )

    let causes = try scenario.journal.events(ofType: .clauseInvalidated).compactMap { event -> String? in
        if case .clauseInvalidated(_, "c1", let cause) = event.event { return cause }
        return nil
    }
    #expect(causes == ["text_edited"])
    #expect(try scenario.journal.events(ofType: .transcriptionStampVoided).isEmpty)
    // The Operator's edit is the clause's text now (the Board owns the Definition of Done).
    let stored = try scenario.journal.clauses(issueID: scenario.issueOne)[0].text
    #expect(MarkdownEquivalence.rendersSame(stored, editedClause))
    #expect(!MarkdownEquivalence.rendersSame(stored, ourClauseText))
}

@Test("Opening inspection still provenance-tests a Linear-normalised block, which is not Operator-supplied")
func openingInspectionTestsNormalisedBlockForProvenance() async throws {
    let scenario = try await makeReadinessScenario()
    defer { cleanup(scenario) }
    let description = linearDescription(of: try seedRenderedCard(scenario))
    let card = try scenario.journal.card(id: scenario.cardOne)
    let boardObject = object(scenario.issueOne, state: stateTodo, description: description)

    func verdict(_ provenance: ProvenanceVerdict) async throws -> OpeningCardReadiness {
        let readiness = ReadinessCheck(
            provenance: FakeProvenanceTester(verdicts: ["backend": provenance]),
            citations: FakeCitationResolver(resolvable: ["resolvable/story"])
        )
        return try await readiness.inspectAtOpening(
            card: card, object: boardObject, journal: scenario.journal,
            repositories: readinessRepositories, mainlines: ResolvedMainlines()
        )
    }

    #expect(try await verdict(.stale(changedPaths: ["a.swift"])) == .notReady)
    #expect(try await verdict(.clean) == .ready)
    #expect(try scenario.journal.transcriptionBlocks(cardID: scenario.cardOne)[0].content == ourContent)
}
