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
    #expect(parsed.transcriptions[0].commit == "deadbeef")
    #expect(parsed.transcriptions[0].ranges == [:])

    #expect(parsed.transcriptions[1].repository == "spec_source")
    #expect(parsed.transcriptions[1].paths == ["docs/goals.md"])
    #expect(parsed.transcriptions[1].symbol == nil)
    #expect(parsed.transcriptions[1].commit == nil)

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

@Test("""
    A card whose Transcription Block carries content with its own '### Definition of Done', \
    another heading and a checklist-shaped line adds no clauses, and its content is skipped, never parsed \
    (roadmap P9.6)
    """)
func parserHazardTranscribedContentNeverLeaksIntoHeadingsOrClauses() throws {
    let legacy = """
        ### Architectural Brief
        <!-- yh:brief-prose:start id=0 -->
        The real approach.
        <!-- yh:brief-prose:end id=0 -->

        <!-- yh:transcription:start repo=spec_source paths=story.md symbol=- commit=deadbeef -->
        ### Definition of Done
        ### Something
        - [ ] not a clause
        <!-- yh:transcription:end -->

        ### Definition of Done
        - [ ] <!-- yh:clause:c1 --> Real clause (epic/story)
        """

    let parsed = CardManagedBlockParser.parse(block: legacy)

    #expect(parsed.briefProse == "The real approach.")
    #expect(parsed.transcriptions == [ParsedTranscription(
        repository: "spec_source", paths: ["story.md"], symbol: nil, commit: "deadbeef"
    )])
    #expect(parsed.clauses == [ParsedClause(cid: "c1", text: "Real clause", citation: "epic/story")])
}

@Test("A block with ranges parses them from the visible line, which also carries the raw line")
func parserRoundTripsRanges() throws {
    let transcription = TranscriptionBlock(
        repository: "api", paths: ["openapi.yaml", "models.swift"],
        ranges: ["openapi.yaml": [LineRange(start: 120, end: 180), LineRange(start: 200, end: 210)]],
        symbol: "ClassList", mainlineCommit: "deadbeef", content: "x", contentHash: "h", authorSupplied: false
    )
    let rendered = TranscriptionBlockLine.render(transcription).joined(separator: "\n")

    let parsed = CardManagedBlockParser.parse(block: rendered)

    #expect(parsed.transcriptions == [ParsedTranscription(
        repository: "api", paths: ["openapi.yaml", "models.swift"],
        ranges: ["openapi.yaml": [LineRange(start: 120, end: 180), LineRange(start: 200, end: 210)]],
        symbol: "ClassList", commit: "deadbeef",
        line: "Contract: `api` · `openapi.yaml` lines 120–180, 200–210 · `models.swift` · "
            + "symbol `ClassList` · commit `deadbeef`"
    )])
}

@Test("A stamp without ranges= parses to no ranges")
func parserNoRanges() throws {
    let stamp = "<!-- yh:transcription:start repo=api paths=a.swift symbol=- commit=deadbeef -->\n"
        + "<!-- yh:transcription:end -->"
    #expect(CardManagedBlockParser.parse(block: stamp).transcriptions.first?.ranges == [:])
}

@Test("A malformed ranges= field, or one not aligned with the paths, is a failure for a stamp-only block")
func parserMalformedRanges() throws {
    for ranges in ["1-x", "-,-", "", "5-"] {
        let stamp = "<!-- yh:transcription:start repo=api paths=a.swift ranges=\(ranges) symbol=- commit=d -->\n"
            + "<!-- yh:transcription:end -->"
        let parsed = try #require(CardManagedBlockParser.parse(block: stamp).transcriptions.first)
        #expect(parsed.failure != nil, "ranges=\(ranges)")
        #expect(parsed.line == nil)
    }
}

@Test("The rendered reference holds repo, paths, ranges, symbol and commit, and never a transcribed line")
func renderedBlockHoldsReferenceOnly() throws {
    let content = "distinctive line one\ndistinctive line two"
    let transcription = TranscriptionBlock(
        repository: "api", paths: ["openapi.yaml", "models.swift"],
        ranges: ["openapi.yaml": [LineRange(start: 120, end: 180), LineRange(start: 200, end: 210)]],
        symbol: "ClassList", mainlineCommit: "deadbeef", content: content,
        contentHash: ManagedBlockFence.sha256(content), authorSupplied: false
    )
    let rendered = TranscriptionBlockLine.render(transcription)

    #expect(rendered.count == 4)
    #expect(rendered[1] == "<!-- yh:transcription:start repo=api paths=openapi.yaml,models.swift "
        + "ranges=120-180+200-210,- symbol=ClassList commit=deadbeef -->")
    #expect(rendered[2] == "Contract: `api` · `openapi.yaml` lines 120–180, 200–210 · `models.swift` · "
        + "symbol `ClassList` · commit `deadbeef`")
    #expect(rendered[3] == TranscriptionBlockLine.endMarker)
    #expect(!rendered.joined(separator: "\n").contains("distinctive"))
    #expect(!rendered.joined(separator: "\n").contains("hash="))

    let plain = TranscriptionBlock(
        repository: "api", paths: ["a.swift"], mainlineCommit: "deadbeef", content: content,
        contentHash: "h", authorSupplied: false
    )
    let plainLines = TranscriptionBlockLine.render(plain)
    #expect(plainLines[1] == "<!-- yh:transcription:start repo=api paths=a.swift symbol=- commit=deadbeef -->")
    #expect(plainLines[2] == "Contract: `api` · `a.swift` · commit `deadbeef`")
}
