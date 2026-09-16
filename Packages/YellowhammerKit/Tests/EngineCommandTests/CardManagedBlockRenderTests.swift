import Domain
import Foundation
import Testing

@testable import Engine
@testable import Journal

// P5.6: Managed Block rendering and hash-skip (Cards) — basic fields

@Test("Render includes kind, repository, state, block reason, and lane position")
func renderBasicFields() {
    let brief = ArchitecturalBrief(prose: "Test brief", transcriptions: [])
    let block = CardManagedBlock(
        kind: "impl.boilerplate",
        repository: "backend",
        state: .inProgress,
        blockReason: "blocked by check",
        lanePosition: 2,
        laneLength: 3,
        brief: brief,
        definitionOfDone: [],
        attempts: []
    )

    let rendered = block.render()

    #expect(rendered.contains("**Kind:** `impl.boilerplate`"))
    #expect(rendered.contains("**Repository:** `backend`"))
    #expect(rendered.contains("**State:** In Progress — blocked by check"))
    #expect(rendered.contains("**Repo Lane position:** 2 of 3"))
}

@Test("Repository line parses back with DeltaRead.repository(inBlock:)")
func repositoryLineParseable() {
    let brief = ArchitecturalBrief(prose: "Test", transcriptions: [])
    let block = CardManagedBlock(
        kind: "impl.boilerplate",
        repository: "backend",
        state: .todo,
        lanePosition: 1,
        laneLength: 1,
        brief: brief,
        definitionOfDone: [],
        attempts: []
    )

    let rendered = block.render()
    let parsed = DeltaRead.repository(inBlock: rendered)

    #expect(parsed == "backend")
}

@Test("State without block reason omits the reason part")
func stateWithoutBlockReasonOmitsReason() {
    let brief = ArchitecturalBrief(prose: "Test", transcriptions: [])
    let block = CardManagedBlock(
        kind: "impl.boilerplate",
        repository: "backend",
        state: .done,
        blockReason: nil,
        lanePosition: 1,
        laneLength: 1,
        brief: brief,
        definitionOfDone: [],
        attempts: []
    )

    let rendered = block.render()

    #expect(rendered.contains("**State:** Done"))
    #expect(!rendered.contains(" — "))
}

@Test("Architectural Brief renders prose and transcription blocks")
func renderArchitecturalBrief() {
    let transcription = TranscriptionBlock(
        repository: "backend",
        paths: ["main.swift", "utils.swift"],
        symbol: "MyClass",
        mainlineCommit: "abc123def",
        content: "func example() {}",
        contentHash: "xyz789",
        authorSupplied: false
    )
    let brief = ArchitecturalBrief(prose: "This is the brief", transcriptions: [transcription])
    let block = CardManagedBlock(
        kind: "impl.boilerplate",
        repository: "backend",
        state: .todo,
        lanePosition: 1,
        laneLength: 1,
        brief: brief,
        definitionOfDone: [],
        attempts: []
    )

    let rendered = block.render()

    #expect(rendered.contains("### Architectural Brief"))
    #expect(rendered.contains("This is the brief"))
    let expectedComment = (
        "<!-- yh:transcription:start repo=backend paths=main.swift,utils.swift "
        + "symbol=MyClass commit=abc123def hash=xyz789 -->"
    )
    #expect(rendered.contains(expectedComment))
    #expect(rendered.contains("func example() {}"))
    #expect(rendered.contains("<!-- yh:transcription:end -->"))
}

@Test("Operator-supplied transcription shows Operator-supplied as commit")
func operatorSuppliedTranscription() {
    let transcription = TranscriptionBlock(
        repository: "backend",
        paths: ["config.json"],
        symbol: nil,
        mainlineCommit: nil,
        content: "{ \"key\": \"value\" }",
        contentHash: "hash456",
        authorSupplied: true,
        authorSuppliedNight: NightStart(rawValue: "2026-01-15T08:30:00Z")
    )
    let brief = ArchitecturalBrief(prose: "Brief", transcriptions: [transcription])
    let block = CardManagedBlock(
        kind: "impl.boilerplate",
        repository: "backend",
        state: .todo,
        lanePosition: 1,
        laneLength: 1,
        brief: brief,
        definitionOfDone: [],
        attempts: []
    )

    let rendered = block.render()

    #expect(rendered.contains("commit=Operator-supplied"))
}

@Test("Definition of Done with clauses renders with checkboxes and citations")
func renderDoD() {
    let clauses = [
        DoDClause(
            cid: "c1", text: "implement feature", citation: "epic/story",
            citationProvenance: "epic/story"
        ),
        DoDClause(
            cid: "c2", text: "add tests", citation: "epic/story",
            citationProvenance: "epic/story"
        )
    ]
    let brief = ArchitecturalBrief(prose: "Brief", transcriptions: [])
    let block = CardManagedBlock(
        kind: "impl.boilerplate",
        repository: "backend",
        state: .todo,
        lanePosition: 1,
        laneLength: 1,
        brief: brief,
        definitionOfDone: clauses,
        attempts: []
    )

    let rendered = block.render()

    #expect(rendered.contains("### Definition of Done"))
    #expect(rendered.contains("- [ ] <!-- yh:clause:c1 --> implement feature (epic/story)"))
    #expect(rendered.contains("- [ ] <!-- yh:clause:c2 --> add tests (epic/story)"))
}

@Test("Empty Definition of Done shows no clauses message")
func renderEmptyDoD() {
    let brief = ArchitecturalBrief(prose: "Brief", transcriptions: [])
    let block = CardManagedBlock(
        kind: "impl.boilerplate",
        repository: "backend",
        state: .todo,
        lanePosition: 1,
        laneLength: 1,
        brief: brief,
        definitionOfDone: [],
        attempts: []
    )

    let rendered = block.render()

    #expect(rendered.contains("_No clauses authored._"))
}

@Test("Footer is present")
func renderFooter() {
    let brief = ArchitecturalBrief(prose: "Brief", transcriptions: [])
    let block = CardManagedBlock(
        kind: "impl.boilerplate",
        repository: "backend",
        state: .todo,
        lanePosition: 1,
        laneLength: 1,
        brief: brief,
        definitionOfDone: [],
        attempts: []
    )

    let rendered = block.render()

    #expect(rendered.contains(CardManagedBlock.footer))
}

@Test("Render does not contain predecessor, Depends on, or Blocked upstream")
func renderNoBlockingConcepts() {
    let brief = ArchitecturalBrief(prose: "Brief", transcriptions: [])
    let block = CardManagedBlock(
        kind: "impl.boilerplate",
        repository: "backend",
        state: .todo,
        lanePosition: 1,
        laneLength: 1,
        brief: brief,
        definitionOfDone: [],
        attempts: []
    )

    let rendered = block.render()

    #expect(!rendered.contains("predecessor"))
    #expect(!rendered.contains("Depends on"))
    #expect(!rendered.contains("Blocked upstream"))
}

@Test("Render is deterministic")
func renderDeterministic() {
    let brief = ArchitecturalBrief(prose: "Brief", transcriptions: [])
    let block = CardManagedBlock(
        kind: "impl.boilerplate",
        repository: "backend",
        state: .todo,
        lanePosition: 1,
        laneLength: 1,
        brief: brief,
        definitionOfDone: [],
        attempts: []
    )

    let render1 = block.render()
    let render2 = block.render()

    #expect(render1 == render2)
}

@Test("No Attempts shows no attempt message")
func renderNoAttempts() {
    let brief = ArchitecturalBrief(prose: "Brief", transcriptions: [])
    let block = CardManagedBlock(
        kind: "impl.boilerplate",
        repository: "backend",
        state: .todo,
        lanePosition: 1,
        laneLength: 1,
        brief: brief,
        definitionOfDone: [],
        attempts: []
    )

    let rendered = block.render()

    #expect(rendered.contains("### Attempts"))
    #expect(rendered.contains("_No Attempt yet._"))
}
