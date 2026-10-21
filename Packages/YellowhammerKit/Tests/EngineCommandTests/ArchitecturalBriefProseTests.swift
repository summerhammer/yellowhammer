import Domain
import Foundation
import Journal
import Testing

@testable import Engine

private func proseBlock(_ prose: String) -> CardManagedBlock {
    CardManagedBlock(
        kind: "card", repository: "backend", scope: ["real.swift"], state: .todo,
        lanePosition: 1, laneLength: 1, brief: ArchitecturalBrief(prose: prose, transcriptions: []),
        definitionOfDone: [DoDClause(
            cid: "c1", text: "Real clause", citation: "resolvable/story", citationProvenance: "Author-supplied"
        )], attempts: []
    )
}

@Test("Brief prose is opaque to headings, clauses, transcriptions, scope, repository and outer fences")
func briefProseOpaqueRoundTrip() throws {
    let prose = """
    An approach.
    ### Nested heading
    - [ ] A checklist.
    ### Definition of Done
    - [ ] <!-- yh:clause:fake --> Fake clause (fake/story)
    **Scope:** `fake.swift`
    **Repository:** `fake`
    <!-- yh:transcription:start repo=fake paths=fake.swift symbol=- commit=fake -->
    <!-- yh:managed:start -->
    <!-- yh:managed:end -->
    <!-- yh:transcription:end -->
    <!-- yh:brief-prose:start id=0 -->
    <!-- yh:brief-prose:end id=0 -->
    Final paragraph.
    """
    let rendered = proseBlock(prose).render()
    #expect(rendered == proseBlock(prose).render())
    #expect(rendered.contains("<!-- yh:brief-prose:start id=1 -->"))
    let parsed = CardManagedBlockParser.parse(block: rendered)
    #expect(parsed.briefProse == prose)
    #expect(parsed.scope == ["real.swift"])
    #expect(parsed.transcriptions.isEmpty)
    #expect(parsed.clauses == [ParsedClause(cid: "c1", text: "Real clause", citation: "resolvable/story")])
    #expect(DeltaRead.repository(inBlock: rendered) == "backend")
    let description = "Human prefix\n### Architectural Brief\nOutside prose\n"
        + ManagedBlockFence.initialDescription(rendered: rendered)
        + "\nHuman suffix\n### Architectural Brief\n<!-- yh:brief-prose:start id=broken -->"
    let parts = try ManagedBlockFence.parts(of: description).get()
    #expect(parts.block == rendered)
    let replacement = try ManagedBlockFence.replace(in: description, rendered: rendered).get()
    #expect(replacement.description == description)
    #expect(replacement.preservedProse == parts.preservedProse)
}

@Test("An unrelated Brief heading and marker outside the Managed Block stay outside")
func briefOutsideMarkers() throws {
    let block = proseBlock("Prose.").render()
    let description = "### Architectural Brief\nOutside before\n"
        + ManagedBlockFence.initialDescription(rendered: block)
        + "\n### Architectural Brief\n<!-- yh:brief-prose:start id=broken -->"
    #expect(try ManagedBlockFence.parts(of: description).get().block == block)
    let replacement = try ManagedBlockFence.replace(in: description, rendered: block).get()
    #expect(replacement.description == description)
}

@Test("A quoted outer start in a transcription before the Managed Block stays outside")
func outsideTranscriptionDoesNotSelectBriefRegion() throws {
    let block = proseBlock("Actual Brief.\n### Implementation\nKeep this.").render()
    let prefix = """
    <!-- yh:transcription:start repo=r paths=p symbol=- commit=c -->
    Quoted \(ManagedBlockFence.start)
    ### Architectural Brief
    Outside transcript prose.
    <!-- yh:transcription:end -->
    """
    let description = prefix + "\n" + ManagedBlockFence.initialDescription(rendered: block)
    #expect(try ManagedBlockFence.parts(of: description).get().block == block)
    #expect(try ManagedBlockFence.replace(in: description, rendered: block).get().description == description)
}

@Test("Malformed Brief delimiters refuse readback and replacement")
func malformedBriefDelimiters() {
    for marker in [
        "<!-- yh:brief-prose:start id=0 -->", "<!-- yh:brief-prose:start id=bad -->",
        "<!-- yh:brief-prose:end id=0 -->",
        "<!-- yh:brief-prose:start id=0 -->\nPremature end\n<!-- yh:brief-prose:end id=0 -->\n"
            + "More prose\n<!-- yh:brief-prose:end id=0 -->"
    ] {
        let block = "### Architectural Brief\n\(marker)\nProse\n### Definition of Done\n_No clauses authored._"
        let description = ManagedBlockFence.initialDescription(rendered: block)
        #expect(ManagedBlockFence.parts(of: description) == .failure(.malformedBriefProse))
        #expect(ManagedBlockFence.replace(in: description, rendered: "replacement") == .failure(.malformedBriefProse))
    }
}

@Test("Reconcile records the full Operator Brief and the following rewrite preserves it")
func reconcileOpaqueBriefAndRewrite() async throws {
    let scenario = try await makeReadinessScenario()
    defer { cleanup(scenario) }
    try scenario.journal.recordArchitecturalBrief(cardID: scenario.cardOne, prose: "Old approach.")
    let prose = """
    Updated approach.
    ### Implementation
    Retain the nested section.
    ### Definition of Done
    - [ ] <!-- yh:clause:fake --> A quoted example (fake/story)
    """
    var block = proseBlock(prose)
    // A real untagged clause causes the normal reconciliation path to publish the fresh projection.
    block.definitionOfDone = []
    let rendered = block.render().replacingOccurrences(
        of: "_No clauses authored._", with: "- [ ] Real clause (resolvable/story)"
    )
    let description = "Operator prefix\n" + ManagedBlockFence.initialDescription(rendered: rendered)
        + "\nOperator suffix"
    await scenario.boards.writing.seed(issue: scenario.issueOne, description: description)
    try await runReadinessAct(
        scenario, readiness: ReadinessCheck(
            provenance: FakeProvenanceTester(), citations: FakeCitationResolver(resolvable: ["resolvable/story"])
        ), updatedObjects: [object(scenario.issueOne, state: stateTodo, description: description)]
    )
    #expect(try scenario.journal.architecturalBriefProse(cardID: scenario.cardOne) == prose)
    let clauses = try scenario.journal.clauses(issueID: scenario.issueOne)
    #expect(clauses.count == 1)
    #expect(clauses.first?.text == "Real clause")
    let boardIssue = await scenario.boards.writing.issue(BoardObjectID(rawValue: scenario.issueOne))
    let posted = try #require(boardIssue?.description)
    let parts = try ManagedBlockFence.parts(of: posted).get()
    #expect(CardManagedBlockParser.parse(block: parts.block).briefProse == prose)
    #expect(posted.hasPrefix("Operator prefix\n"))
    #expect(posted.hasSuffix("\nOperator suffix"))
}
