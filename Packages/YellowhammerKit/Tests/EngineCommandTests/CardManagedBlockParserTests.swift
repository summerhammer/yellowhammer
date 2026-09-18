import Domain
import Foundation
import Journal
import Testing

@testable import Engine

@Test("Parsing round-trips a rendered block's brief, transcriptions and clauses")
func parserRoundTripsRenderedBlock() throws {
    let transcription1 = TranscriptionBlock(
        repository: "backend", paths: ["a.swift", "b.swift"], symbol: "Foo", mainlineCommit: "deadbeef",
        content: "func foo() {}", contentHash: ManagedBlockFence.sha256("func foo() {}"), authorSupplied: false
    )
    let transcription2 = TranscriptionBlock(
        repository: "spec_source", paths: ["docs/goals.md"], symbol: nil, mainlineCommit: nil,
        content: "Goal text", contentHash: ManagedBlockFence.sha256("Goal text"), authorSupplied: true
    )
    let brief = ArchitecturalBrief(
        prose: "This Card wires the new endpoint.", transcriptions: [transcription1, transcription2]
    )
    let clauses = [
        DoDClause(cid: "c1", text: "First clause", citation: "epic/story", citationProvenance: "machine-found"),
        DoDClause(cid: "c2", text: "Second clause", citation: "G1", citationProvenance: "machine-found"),
        DoDClause(cid: "c3", text: "Third clause", citation: "epic/other", citationProvenance: "Author-supplied")
    ]
    let block = CardManagedBlock(
        kind: "card", repository: "backend", scope: ["Sources/App/", "Secrets/key.env"], state: .todo,
        lanePosition: 1, laneLength: 3, brief: brief, definitionOfDone: clauses, attempts: []
    )

    let rendered = block.render()
    let parsed = CardManagedBlockParser.parse(block: rendered)

    #expect(parsed.briefProse == "This Card wires the new endpoint.")
    #expect(parsed.scope == ["Sources/App/", "Secrets/key.env"])

    #expect(parsed.transcriptions.count == 2)
    #expect(parsed.transcriptions[0].repository == "backend")
    #expect(parsed.transcriptions[0].paths == ["a.swift", "b.swift"])
    #expect(parsed.transcriptions[0].symbol == "Foo")
    #expect(parsed.transcriptions[0].commitField == "deadbeef")
    #expect(parsed.transcriptions[0].content == "func foo() {}")
    #expect(parsed.transcriptions[0].contentHash == transcription1.contentHash)

    #expect(parsed.transcriptions[1].repository == "spec_source")
    #expect(parsed.transcriptions[1].paths == ["docs/goals.md"])
    #expect(parsed.transcriptions[1].symbol == nil)
    #expect(parsed.transcriptions[1].commitField == "Operator-supplied")
    #expect(parsed.transcriptions[1].content == "Goal text")

    #expect(parsed.clauses.count == 3)
    #expect(parsed.clauses[0] == ParsedClause(cid: "c1", text: "First clause", citation: "epic/story"))
    #expect(parsed.clauses[1] == ParsedClause(cid: "c2", text: "Second clause", citation: "G1"))
    #expect(parsed.clauses[2] == ParsedClause(cid: "c3", text: "Third clause", citation: "epic/other"))
}

@Test("An untagged clause line and a line without a citation parse without a cid or citation")
func parserHandlesUntaggedAndCitationlessLines() throws {
    let block = """
    ### Definition of Done
    - [ ] <!-- yh:clause:c1 --> Tagged clause (epic/story)
    - [ ] An untagged human clause (epic/untagged)
    - [ ] <!-- yh:clause:c2 --> A clause with no citation
    """

    let parsed = CardManagedBlockParser.parse(block: block)

    #expect(parsed.clauses.count == 3)
    #expect(parsed.clauses[0] == ParsedClause(cid: "c1", text: "Tagged clause", citation: "epic/story"))
    #expect(parsed.clauses[1] == ParsedClause(cid: nil, text: "An untagged human clause", citation: "epic/untagged"))
    #expect(parsed.clauses[2] == ParsedClause(cid: "c2", text: "A clause with no citation", citation: nil))
}

@Test("No clauses authored parses to an empty clause list")
func parserHandlesNoClausesAuthored() throws {
    let block = """
    ### Definition of Done
    _No clauses authored._

    ### Attempts
    _No Attempt yet._
    """

    let parsed = CardManagedBlockParser.parse(block: block)
    #expect(parsed.clauses.isEmpty)
}

@Test("No brief prose parses to nil")
func parserHandlesEmptyBrief() throws {
    let block = """
    ### Architectural Brief

    ### Definition of Done
    _No clauses authored._
    """

    let parsed = CardManagedBlockParser.parse(block: block)
    #expect(parsed.briefProse == nil)
}

@Test("No Scope line parses to nil")
func parserHandlesMissingScopeLine() throws {
    let block = """
    **Kind:** `card`
    **Repository:** `backend`
    """

    let parsed = CardManagedBlockParser.parse(block: block)
    #expect(parsed.scope == nil)
}

@Test("A none-declared Scope line parses to an empty array")
func parserHandlesScopeNoneDeclared() throws {
    let block = """
    **Kind:** `card`
    **Repository:** `backend`
    **Scope:** _none declared_
    """

    let parsed = CardManagedBlockParser.parse(block: block)
    #expect(parsed.scope == [])
}
