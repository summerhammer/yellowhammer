import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
import Journal
import Repositories
import Testing

// spec: feature-authoring/author-an-architectural-brief#edited-reference — see EditedReferenceFixtures.swift.

/// A find-and-replace the Operator makes on the board's `Contract:` line, and what the reason should say.
struct UnreadableEdit {
    let find: String
    let replace: String
    let reason: String

    init(_ find: String, _ replace: String, _ reason: String) {
        self.find = find
        self.replace = replace
        self.reason = reason
    }
}

@Suite("Readiness Check: an Operator's edit to a Transcription Block reference")
struct EditedReferenceReadinessTests {
    @Test("An edited range is read at the next dispatch: the new lines, Operator-supplied as of this Night")
    func editedRangeIsRead() async throws {
        let rig = try await EditRig.make("edited-range-1")
        let scenario = try await makeReadinessScenario()
        defer { cleanup(scenario) }
        try seedEdited(scenario, blocks: [rig.authoredBlock()])
        let description = editedBoardDescription(blocks: [rig.authoredBlock()]) {
            $0.replacingOccurrences(of: "lines 2–3", with: "lines 5–6")
        }

        try await runEdited(scenario, rig: rig, readiness: editedReadiness(), description: description)

        let record = try #require(try scenario.journal.transcriptionBlocks(cardID: scenario.cardOne).first)
        #expect(record.isRead)
        #expect(record.content == "new 5\nnew 6")
        #expect(record.contentHash == MainlineReader.sha256("new 5\nnew 6"))
        #expect(record.ranges == ["api.txt": [LineRange(start: 5, end: 6)]])
        #expect(record.mainlineCommit == rig.second)
        #expect(record.authorSupplied)
        #expect(record.authorSuppliedNight == readinessNightStart)
        #expect(record.referenceText == nil)
        #expect(scenario.recorder.seen.map(\.issueID).contains(scenario.issueOne))
        // A readable edit tells the Operator nothing, and the Managed Block is rewritten exactly once.
        #expect(await scenario.boards.writing.comments.filter { $0.body.contains("not Ready") }.isEmpty)
        #expect(try editedManagedBlockWrites(scenario) == 1)
        let posted = await editedBoardCopy(scenario)
        #expect(posted.contains("lines 5–6 · commit `\(rig.second)` · Operator-supplied, as of 2026-09-17"))

        // The lines are held in the Journal and served at the next dispatch, unchanged.
        guard case .ready(let ready) = try await directEvaluate(
            scenario, cardID: scenario.cardOne, readiness: editedReadiness(), repositories: rig.repositories
        ) else {
            Issue.record("expected ready")
            return
        }
        #expect(ready.brief.transcriptions.map(\.content) == ["new 5\nnew 6"])
        #expect(ready.brief.transcriptions.map(\.authorSupplied) == [true])
    }

    @Test("An edit to an older mainline commit reads that commit's lines, and the Readiness Check diffs from it")
    func editedCommitDivergesFromThere() async throws {
        let rig = try await EditRig.make("edited-commit-2")
        let scenario = try await makeReadinessScenario()
        defer { cleanup(scenario) }
        try seedEdited(scenario, blocks: [rig.authoredBlock()])
        let description = editedBoardDescription(blocks: [rig.authoredBlock()]) {
            $0.replacingOccurrences(of: rig.second, with: String(rig.first.prefix(9)))
        }

        try await runEdited(scenario, rig: rig, readiness: editedReadiness(), description: description)

        let record = try #require(try scenario.journal.transcriptionBlocks(cardID: scenario.cardOne).first)
        #expect(record.content == "old 2\nold 3")
        #expect(record.mainlineCommit == rig.first)
        #expect(record.authorSupplied)
        // api.txt moved after the edited commit: a Divergence, tested from the edited commit.
        let card = try #require(try scenario.journal.card(issueID: scenario.issueOne))
        #expect(card.state == .waitingOnYou)
        #expect(card.waitingReason == .divergence)
        #expect(try scenario.journal.events(ofType: .cardDiverged).count == 1)
    }

    enum Unreadable: String, CaseIterable {
        case offMainline, unresolvable, outOfRange, directory, noCommit, unparseable

        func edit(_ rig: EditRig) -> UnreadableEdit {
            switch self {
            case .offMainline:
                UnreadableEdit("commit `\(rig.second)`", "commit `\(rig.side)`", "is not on backend's mainline")
            case .unresolvable:
                UnreadableEdit(
                    "commit `\(rig.second)`", "commit `\(String(repeating: "0", count: 40))`", "could not be resolved"
                )
            case .outOfRange:
                UnreadableEdit("lines 2–3", "lines 50–60", "is out of bounds")
            case .directory:
                UnreadableEdit("`api.txt` lines 2–3", "`docs`", "not a regular file")
            case .noCommit:
                UnreadableEdit(" · commit `\(rig.second)`", "", "it names no commit")
            case .unparseable:
                UnreadableEdit("`api.txt` lines 2–3", "nonsense", "is not a path, symbol or commit")
            }
        }
    }

    @Test("An edit that cannot be read makes the Card not Ready, with the reason on the Card and no Attempt",
          arguments: Unreadable.allCases)
    func unreadableEditIsNotReady(_ kind: Unreadable) async throws {
        let rig = try await EditRig.make("edited-unreadable-\(kind.rawValue)")
        let scenario = try await makeReadinessScenario()
        defer { cleanup(scenario) }
        try seedEdited(scenario, blocks: [rig.authoredBlock()])
        let edit = kind.edit(rig)
        let editedLine = rig.authoredLine.replacingOccurrences(of: edit.find, with: edit.replace)
        let description = editedBoardDescription(blocks: [rig.authoredBlock()]) {
            $0.replacingOccurrences(of: edit.find, with: edit.replace)
        }

        try await runEdited(scenario, rig: rig, readiness: editedReadiness(), description: description)

        #expect(!scenario.recorder.seen.map(\.issueID).contains(scenario.issueOne))
        let failed = try scenario.journal.events(ofType: .readinessCheckFailed).compactMap { record -> [String]? in
            if case .readinessCheckFailed(_, let issueID, let failures) = record.event, issueID == scenario.issueOne {
                return failures
            }
            return nil
        }
        let failures = try #require(failed.first)
        #expect(failures.count == 1)
        #expect(failures[0].hasPrefix("the edited Transcription Block reference "))
        #expect(failures[0].contains(edit.reason), "\(failures[0])")
        // The reason is on the Card.
        let comments = await scenario.boards.writing.comments.map(\.body)
        #expect(comments.contains { $0.contains("not Ready") && $0.contains(edit.reason) })
        #expect(try scenario.journal.attemptHistory(cardID: scenario.cardOne).attemptCount == 0)

        // The edit stays recorded, unread, and the Card still shows the Operator's own line.
        let record = try #require(try scenario.journal.transcriptionBlocks(cardID: scenario.cardOne).first)
        #expect(!record.isRead)
        #expect(record.referenceText == editedLine)
        #expect(await editedBoardCopy(scenario).contains(editedLine))

        // The next evaluation, with no Delta Read change for the Card, tries the read again.
        guard case .notReady(let again) = try await directEvaluate(
            scenario, cardID: scenario.cardOne, readiness: editedReadiness(), repositories: rig.repositories
        ) else {
            Issue.record("expected notReady")
            return
        }
        #expect(again.count == 1)
        guard case .referenceUnreadable(_, let reference, let reason) = again[0] else {
            Issue.record("expected referenceUnreadable, got \(again[0])")
            return
        }
        #expect(reference == editedLine)
        #expect(reason.contains(edit.reason))
    }

    @Test("An unreadable edit is made good by a later edit, and the Card is Ready again")
    func laterEditRecovers() async throws {
        let rig = try await EditRig.make("edited-recovers-3")
        let scenario = try await makeReadinessScenario()
        defer { cleanup(scenario) }
        try seedEdited(scenario, blocks: [rig.authoredBlock()])
        let bad = editedBoardDescription(blocks: [rig.authoredBlock()]) {
            $0.replacingOccurrences(of: "lines 2–3", with: "lines 50–60")
        }
        try await runEdited(scenario, rig: rig, readiness: editedReadiness(), description: bad)
        #expect(try scenario.journal.transcriptionBlocks(cardID: scenario.cardOne).first?.isRead == false)

        let good = editedBoardDescription(blocks: [rig.authoredBlock()]) {
            $0.replacingOccurrences(of: "lines 2–3", with: "lines 7–8")
        }
        try await runEdited(scenario, rig: rig, readiness: editedReadiness(), description: good)

        let record = try #require(try scenario.journal.transcriptionBlocks(cardID: scenario.cardOne).first)
        #expect(record.content == "new 7\nnew 8")
        #expect(record.authorSupplied)
    }

    @Test("Whitespace-only and symbol-only changes read nothing and keep the block as it was")
    func noOpEditsReadNothing() async throws {
        let rig = try await EditRig.make("edited-noop-4")
        for kind in ["whitespace", "symbol"] {
            let scenario = try await makeReadinessScenario()
            defer { cleanup(scenario) }
            let reader = CountingReferenceReader()
            try seedEdited(scenario, blocks: [rig.authoredBlock()])
            let description = editedBoardDescription(blocks: [rig.authoredBlock()]) {
                kind == "whitespace"
                    ? $0.replacingOccurrences(of: " · ", with: "   ·   ")
                        .replacingOccurrences(of: "Contract:", with: "  Contract:")
                    : $0.replacingOccurrences(of: " · commit", with: " · symbol `Renamed` · commit")
            }

            try await runEdited(
                scenario, rig: rig, readiness: editedReadiness(provenance: FakeProvenanceTester(), references: reader),
                description: description
            )

            #expect(reader.calls == 0, "\(kind)")
            let record = try #require(try scenario.journal.transcriptionBlocks(cardID: scenario.cardOne).first)
            #expect(record.content == "new 2\nnew 3", "\(kind)")
            #expect(record.mainlineCommit == rig.second)
            #expect(!record.authorSupplied)
            #expect(record.symbol == (kind == "symbol" ? "Renamed" : nil))
            #expect(scenario.recorder.seen.map(\.issueID).contains(scenario.issueOne))
            #expect(await scenario.boards.writing.comments.filter { $0.body.contains("not Ready") }.isEmpty)
        }
    }
}
