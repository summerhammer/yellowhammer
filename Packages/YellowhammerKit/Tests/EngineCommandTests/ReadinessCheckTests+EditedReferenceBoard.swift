import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
import Journal
import Repositories
import Testing

// spec: feature-authoring/author-an-architectural-brief#edited-reference — deleting a reference, the trap of
// an unreadable edit meeting a minted clause, and the opening inspection. Fixtures: EditedReferenceFixtures.swift.

private func block(_ start: Int, _ end: Int, in rig: EditRig) -> TranscriptionBlock {
    let content = (start...end).map { "new \($0)" }.joined(separator: "\n")
    return TranscriptionBlock(
        repository: "backend", paths: ["api.txt"], ranges: ["api.txt": [LineRange(start: start, end: end)]],
        mainlineCommit: rig.second, content: content, contentHash: MainlineReader.sha256(content),
        authorSupplied: false
    )
}

@Suite("Readiness Check: deleting and adding Transcription Block references")
struct EditedReferenceBoardTests {
    @Test("A reference removed whole leaves the Journal and is not restored; its neighbours are kept, not edited")
    func deletionLeavesNeighboursAlone() async throws {
        let rig = try await EditRig.make("edited-delete-1")
        let scenario = try await makeReadinessScenario()
        defer { cleanup(scenario) }
        let reader = CountingReferenceReader()
        let blocks = [block(2, 3, in: rig), block(5, 6, in: rig), block(8, 9, in: rig)]
        try seedEdited(scenario, blocks: blocks)
        let description = editedBoardDescription(blocks: [blocks[0], blocks[2]])

        try await runEdited(
            scenario, rig: rig, readiness: editedReadiness(provenance: FakeProvenanceTester(), references: reader),
            description: description
        )

        #expect(reader.calls == 0)
        let records = try scenario.journal.transcriptionBlocks(cardID: scenario.cardOne)
        #expect(records.map(\.content) == ["new 2\nnew 3", "new 8\nnew 9"])
        #expect(records.map(\.authorSupplied) == [false, false])
        #expect(records.map(\.isRead) == Array(repeating: true, count: records.count))
        // The rewrite is from the Journal, so the removed reference is not restored.
        let posted = await editedBoardCopy(scenario)
        #expect(posted.contains("lines 2–3") && posted.contains("lines 8–9"))
        #expect(!posted.contains("lines 5–6"))
        #expect(try editedManagedBlockWrites(scenario) == 1)
        #expect(scenario.recorder.seen.map(\.issueID).contains(scenario.issueOne))
    }

    @Test("Removing the only reference empties the Journal's blocks and the worker's instruction")
    func onlyReferenceRemoved() async throws {
        let rig = try await EditRig.make("edited-delete-2")
        let scenario = try await makeReadinessScenario()
        defer { cleanup(scenario) }
        try seedEdited(scenario, blocks: [rig.authoredBlock()])

        try await runEdited(
            scenario, rig: rig, readiness: editedReadiness(), description: editedBoardDescription(blocks: [])
        )

        #expect(try scenario.journal.transcriptionBlocks(cardID: scenario.cardOne).isEmpty)
        #expect(!(await editedBoardCopy(scenario)).contains("Contract:"))
        guard case .ready(let ready) = try await directEvaluate(
            scenario, cardID: scenario.cardOne, readiness: editedReadiness(), repositories: rig.repositories
        ) else {
            Issue.record("expected ready")
            return
        }
        #expect(ready.brief.transcriptions.isEmpty)
    }

    @Test("A well-formed reference the Operator adds is a new block, read like an edit")
    func addedReferenceIsRead() async throws {
        let rig = try await EditRig.make("edited-add-3")
        let scenario = try await makeReadinessScenario()
        defer { cleanup(scenario) }
        try seedEdited(scenario, blocks: [rig.authoredBlock()])
        let added = block(8, 9, in: rig)

        try await runEdited(
            scenario, rig: rig, readiness: editedReadiness(),
            description: editedBoardDescription(blocks: [rig.authoredBlock(), added])
        )

        let records = try scenario.journal.transcriptionBlocks(cardID: scenario.cardOne)
        #expect(records.map(\.content) == ["new 2\nnew 3", "new 8\nnew 9"])
        #expect(records.map(\.authorSupplied) == [false, true])
        #expect(records.map(\.isRead) == Array(repeating: true, count: records.count))
    }

    @Test("An unreadable edit and a minted clause in one evaluation: the rewrite keeps the Operator's own line")
    func unreadableEditSurvivesMintedClauseRewrite() async throws {
        let rig = try await EditRig.make("edited-trap-4")
        let scenario = try await makeReadinessScenario()
        defer { cleanup(scenario) }
        try seedEdited(scenario, blocks: [rig.authoredBlock()])
        let editedLine = rig.authoredLine.replacingOccurrences(of: "lines 2–3", with: "lines 50–60")
        let description = editedBoardDescription(blocks: [rig.authoredBlock()]) {
            $0.replacingOccurrences(of: "lines 2–3", with: "lines 50–60")
                .replacingOccurrences(
                    of: "\n\n### Attempts", with: "\n- [ ] An untagged human clause (resolvable/story)\n\n### Attempts"
                )
        }

        try await runEdited(scenario, rig: rig, readiness: editedReadiness(), description: description)

        #expect(try scenario.journal.events(ofType: .clauseMinted).count == 1)
        #expect(try editedManagedBlockWrites(scenario) == 1)
        let posted = await editedBoardCopy(scenario)
        #expect(posted.contains(editedLine))
        #expect(!posted.contains(rig.authoredLine))
        #expect(!scenario.recorder.seen.map(\.issueID).contains(scenario.issueOne))
    }
}

@Suite("Opening inspection of an edited reference")
struct EditedReferenceOpeningTests {
    private func inspect(
        _ scenario: ReadinessScenario, rig: EditRig, description: String?
    ) async throws -> OpeningCardReadiness {
        let card = try #require(try scenario.journal.card(issueID: scenario.issueOne))
        return try await editedReadiness(provenance: FakeProvenanceTester()).inspectAtOpening(
            card: card, object: object(scenario.issueOne, state: stateTodo, description: description),
            journal: scenario.journal, repositories: rig.repositories, mainlines: ResolvedMainlines()
        )
    }

    private func expect(
        _ expected: OpeningCardReadiness, _ scenario: ReadinessScenario, _ rig: EditRig, _ description: String?,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let verdict = try await inspect(scenario, rig: rig, description: description)
        #expect(verdict == expected, sourceLocation: sourceLocation)
    }

    @Test("Unedited, whitespace-edited and symbol-edited references leave the Card Ready; anything else is unknown")
    func openingVerdicts() async throws {
        let rig = try await EditRig.make("edited-opening-1")
        let scenario = try await makeReadinessScenario()
        defer { cleanup(scenario) }
        try seedEdited(scenario, blocks: [rig.authoredBlock()])
        let authored = [rig.authoredBlock()]

        try await expect(.ready, scenario, rig, editedBoardDescription(blocks: authored))
        let spaced = editedBoardDescription(blocks: authored) { $0.replacingOccurrences(of: " · ", with: "  ·  ") }
        try await expect(.ready, scenario, rig, spaced)
        let symbol = editedBoardDescription(blocks: authored) {
            $0.replacingOccurrences(of: " · commit", with: " · symbol `Renamed` · commit")
        }
        try await expect(.ready, scenario, rig, symbol)

        let edited = editedBoardDescription(blocks: authored) {
            $0.replacingOccurrences(of: "lines 2–3", with: "lines 5–6")
        }
        try await expect(.unknown, scenario, rig, edited)
        let removed = editedBoardDescription(blocks: [])
        try await expect(.unknown, scenario, rig, removed)
        let added = editedBoardDescription(blocks: authored + [block(8, 9, in: rig)])
        try await expect(.unknown, scenario, rig, added)
    }

    @Test("A reference that is still unread in the Journal is unknown, whatever the board says")
    func unreadRecordIsUnknown() async throws {
        let rig = try await EditRig.make("edited-opening-2")
        let scenario = try await makeReadinessScenario()
        defer { cleanup(scenario) }
        try seedEdited(scenario, blocks: [])
        try scenario.journal.replaceTranscriptionBlocks(cardID: scenario.cardOne, [NewTranscriptionBlock(
            repository: "backend", paths: ["api.txt"], ranges: [:], symbol: nil, mainlineCommit: rig.second,
            content: nil, contentHash: nil, authorSupplied: true, referenceText: rig.authoredLine
        )])

        try await expect(.unknown, scenario, rig, nil)
    }
}

@Suite("Matching board Transcription Blocks to the Journal's records")
struct TranscriptionReferenceMatchTests {
    private func record(
        _ id: Int64, paths: [String] = ["a.md"], ranges: [String: [LineRange]] = [:], symbol: String? = nil,
        commit: String? = String(repeating: "a", count: 40), referenceText: String? = nil, read: Bool = true
    ) -> TranscriptionBlockRecord {
        TranscriptionBlockRecord(
            id: id, cardID: 1, repository: "api", paths: paths, ranges: ranges, symbol: symbol,
            mainlineCommit: commit, content: read ? "x" : nil, contentHash: read ? "h" : nil, authorSupplied: false,
            authorSuppliedNightID: nil, referenceText: referenceText
        )
    }

    private func board(
        paths: [String] = ["a.md"], ranges: [String: [LineRange]] = [:], symbol: String? = nil,
        commit: String? = String(repeating: "a", count: 40), line: String? = nil, failure: String? = nil
    ) -> ParsedTranscription {
        ParsedTranscription(
            repository: failure == nil ? "api" : "", paths: paths, ranges: ranges, symbol: symbol, commit: commit,
            line: line, failure: failure
        )
    }

    private func kinds(_ matching: TranscriptionMatching) -> [String] {
        matching.blocks.map {
            switch $0 {
            case .kept(let record, _): "kept \(record.id)"
            case .edited: "edited"
            }
        }
    }

    @Test("Never by position: deleting block 2 of 3 keeps 1 and 3 and reports 2 as deleted")
    func middleDeleted() {
        let records = [record(1, paths: ["one.md"]), record(2, paths: ["two.md"]), record(3, paths: ["three.md"])]
        let matching = TranscriptionReferenceMatch.match(
            board: [board(paths: ["one.md"]), board(paths: ["three.md"])], records: records
        )
        #expect(kinds(matching) == ["kept 1", "kept 3"])
        #expect(matching.deletions.map(\.id) == [2])
    }

    @Test("A reordered board keeps every block, in board order")
    func reordered() {
        let records = [record(1, paths: ["one.md"]), record(2, paths: ["two.md"])]
        let matching = TranscriptionReferenceMatch.match(
            board: [board(paths: ["two.md"]), board(paths: ["one.md"])], records: records
        )
        #expect(kinds(matching) == ["kept 2", "kept 1"])
        #expect(matching.deletions.isEmpty)
    }

    @Test("Identical references each take a record of their own")
    func duplicates() {
        let matching = TranscriptionReferenceMatch.match(
            board: [board(), board(), board()], records: [record(1), record(2)]
        )
        #expect(kinds(matching) == ["kept 1", "kept 2", "edited"])
    }

    @Test("A changed repository, path, range or commit is an edit; a changed symbol is not")
    func whatCounts() {
        let base = [record(1, ranges: ["a.md": [LineRange(start: 3, end: 5)]], symbol: "Old")]
        func match(_ parsed: ParsedTranscription) -> String {
            kinds(TranscriptionReferenceMatch.match(board: [parsed], records: base))[0]
        }
        let ranges = ["a.md": [LineRange(start: 3, end: 5)]]
        #expect(match(board(ranges: ranges, symbol: "New")) == "kept 1")
        #expect(match(board(ranges: ranges, symbol: nil)) == "kept 1")
        #expect(match(board(paths: ["b.md"], ranges: ranges)) == "edited")
        #expect(match(board(ranges: ["a.md": [LineRange(start: 3, end: 6)]])) == "edited")
        #expect(match(board(ranges: [:])) == "edited")
        #expect(match(board(ranges: ranges, commit: String(repeating: "b", count: 40))) == "edited")
        #expect(match(board(ranges: ranges, commit: nil)) == "edited")
    }

    @Test("A symbol-only edit is kept with the board's symbol")
    func symbolTravels() {
        let matching = TranscriptionReferenceMatch.match(
            board: [board(symbol: "New")], records: [record(1, symbol: "Old")]
        )
        guard case .kept(_, let symbol) = matching.blocks[0] else {
            Issue.record("expected kept")
            return
        }
        #expect(symbol == "New")
    }

    @Test("A commit of at least 7 characters that prefixes the resolved sha is the same commit; shorter is not")
    func abbreviatedCommit() {
        let full = "abcdef0123456789abcdef0123456789abcdef01"
        let records = [record(1, commit: full)]
        let seven = TranscriptionReferenceMatch.match(board: [board(commit: "abcdef0")], records: records)
        #expect(kinds(seven) == ["kept 1"])
        let six = TranscriptionReferenceMatch.match(board: [board(commit: "abcdef")], records: records)
        #expect(kinds(six) == ["edited"])
    }

    @Test("Ranges compare as unions when well-formed, and as written when not")
    func rangeNormalisation() {
        let records = [record(1, ranges: ["a.md": [LineRange(start: 1, end: 9)]])]
        let overlapping = board(ranges: ["a.md": [LineRange(start: 6, end: 9), LineRange(start: 1, end: 5)]])
        #expect(kinds(TranscriptionReferenceMatch.match(board: [overlapping], records: records)) == ["kept 1"])

        let malformed = ["a.md": [LineRange(start: 9, end: 3)]]
        let unread = [record(1, ranges: malformed, referenceText: nil, read: false)]
        let matching = TranscriptionReferenceMatch.match(board: [board(ranges: malformed)], records: unread)
        #expect(kinds(matching) == ["kept 1"])
    }

    @Test("An unread edit seen again unchanged is kept, parseable or not; a different line is an edit")
    func unreadEditSeenAgain() {
        let line = "Contract: `api` · nonsense"
        let unread = [record(1, paths: [], commit: nil, referenceText: line, read: false)]
        let same = board(paths: [], commit: nil, line: "Contract:   `api` ·   nonsense", failure: "bad")
        #expect(kinds(TranscriptionReferenceMatch.match(board: [same], records: unread)) == ["kept 1"])
        let other = board(paths: [], commit: nil, line: "Contract: `api` · other", failure: "bad")
        #expect(kinds(TranscriptionReferenceMatch.match(board: [other], records: unread)) == ["edited"])
    }
}
