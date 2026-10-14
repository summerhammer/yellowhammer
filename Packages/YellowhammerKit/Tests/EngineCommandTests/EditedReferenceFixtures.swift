import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
import Journal
import Repositories
import Synchronization
import Testing

// spec: feature-authoring/author-an-architectural-brief#edited-reference — an Operator's edit to a
// Transcription Block's visible `Contract:` line is honoured as a new reference, read at dispatch from local
// mainline at the edited commit. Real git (a fixture repository) wherever a read matters; a counting fake
// reader only where the assertion is that nothing was read. Fixture helpers live in ReadinessCheckTests.swift.

/// Counts reads; reads nothing.
final class CountingReferenceReader: ReferenceReading {
    private let count = Mutex(0)
    var calls: Int { count.withLock { $0 } }

    func read(
        _ record: TranscriptionBlockRecord, in projectRepositories: ProjectRepositories, mainlines: ResolvedMainlines
    ) async -> Result<TranscriptionBlock, ReferenceReadFailure> {
        count.withLock { $0 += 1 }
        return .failure(ReferenceReadFailure(reason: "the counting fake reads nothing"))
    }
}

/// A `backend` fixture repository: `api.txt` reads `old N` at `first` and `new N` at `second` (the mainline
/// head); `docs/readme.md` is a directory's file; `side` is a commit on a branch mainline does not contain.
final class EditRig {
    let fixture: EngineGitFixture
    let repositories: ProjectRepositories
    let first: String
    let second: String
    let side: String

    init(
        fixture: consuming EngineGitFixture, repositories: ProjectRepositories, first: String, second: String,
        side: String
    ) {
        self.fixture = fixture
        self.repositories = repositories
        self.first = first
        self.second = second
        self.side = side
    }

    static func make(_ name: String) async throws -> EditRig {
        let fixture = EngineGitFixture(name: name)
        await fixture.initRepo()
        func file(_ prefix: String) -> String { (1...12).map { "\(prefix) \($0)" }.joined(separator: "\n") + "\n" }
        let first = try await fixture.commit(filename: "api.txt", content: file("old"))
        try await fixture.commit(filename: "docs/readme.md", content: "docs")
        let second = try await fixture.commit(filename: "api.txt", content: file("new"))
        await fixture.run(["checkout", "-b", "side", first])
        let side = try await fixture.commit(filename: "side.txt", content: "side")
        await fixture.run(["checkout", "main"])
        let repo = Repo(name: "backend", path: fixture.path, role: .backend)
        return EditRig(
            fixture: fixture, repositories: ProjectRepositories(workingRepos: [repo]), first: first, second: second,
            side: side
        )
    }

    /// The block the Journal holds before any edit: `api.txt` lines 2–3 as read at the mainline head.
    func authoredBlock(symbol: String? = nil) -> TranscriptionBlock {
        TranscriptionBlock(
            repository: "backend", paths: ["api.txt"], ranges: ["api.txt": [LineRange(start: 2, end: 3)]],
            symbol: symbol, mainlineCommit: second, content: "new 2\nnew 3",
            contentHash: MainlineReader.sha256("new 2\nnew 3"), authorSupplied: false
        )
    }

    var authoredLine: String { TranscriptionBlockLine.render(authoredBlock())[2] }
}

let editedClause = DoDClause(
    cid: "c1", text: "A clause", citation: "resolvable/story", citationProvenance: "Author-supplied"
)

func seedEdited(_ scenario: ReadinessScenario, blocks: [TranscriptionBlock]) throws {
    try scenario.journal.recordArchitecturalBrief(cardID: scenario.cardOne, prose: "A brief.")
    try scenario.journal.insertClause(JournalStore.NewClause(
        cid: "c1", issueID: scenario.issueOne, level: "card", text: "A clause",
        locationID: "resolvable/story", provenance: "Author-supplied", citationProvenance: "Author-supplied"
    ))
    try scenario.journal.recordTranscriptionBlocks(cardID: scenario.cardOne, blocks)
}

/// The board's copy of the Card's Managed Block for `blocks`, passed through `edit` (the Operator's hand).
func editedBoardDescription(blocks: [TranscriptionBlock], edit: (String) -> String = { $0 }) -> String {
    let rendered = CardManagedBlock(
        kind: "card", repository: "backend", state: .todo, lanePosition: 1, laneLength: 2,
        brief: ArchitecturalBrief(prose: "A brief.", transcriptions: blocks),
        definitionOfDone: [editedClause], attempts: []
    ).render()
    return fenced(block: edit(rendered))
}

func editedReadiness(
    provenance: any ProvenanceTesting = ProvenanceDiffTester(), references: any ReferenceReading = MainlineReader()
) -> ReadinessCheck {
    ReadinessCheck(
        provenance: provenance, citations: FakeCitationResolver(resolvable: ["resolvable/story"]),
        references: references
    )
}

/// Runs the build Act with the board's edited description delivered through the Delta Read.
func runEdited(
    _ scenario: ReadinessScenario, rig: EditRig, readiness: ReadinessCheck, description: String
) async throws {
    await scenario.boards.writing.seed(issue: scenario.issueOne, description: description)
    try await runReadinessAct(
        scenario, readiness: readiness,
        updatedObjects: [object(scenario.issueOne, state: stateTodo, description: description)],
        repositories: rig.repositories
    )
}

func editedBoardCopy(_ scenario: ReadinessScenario) async -> String {
    await scenario.boards.writing.issue(BoardObjectID(rawValue: scenario.issueOne))?.description ?? ""
}

func editedManagedBlockWrites(_ scenario: ReadinessScenario) throws -> Int {
    try scenario.journal.events(ofType: .managedBlockWritten).filter {
        if case .managedBlockWritten(let issueID, _, _) = $0.event { return issueID == scenario.issueOne }
        return false
    }.count
}
