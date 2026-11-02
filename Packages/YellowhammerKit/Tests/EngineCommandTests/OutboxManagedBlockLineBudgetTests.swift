import Domain
import Foundation
import Testing

@testable import Engine
@testable import Journal

// issue #670 (board-projection/maintain-the-managed-block, budget on rewrite): a targeted report update
// compacts down the report's ladder, keeps every other line of the block and the Operator's prose, and when
// nothing fits names the report, not a lowered budget or a longer Route id, as what could not be written.

@Suite("Outbox: description budget on a targeted report update (#670)")
struct OutboxManagedBlockLineBudgetTests {
    private let limit = BoardDescriptionLimit(maximum: 100_000, unit: .utf16CodeUnits)
    private let prefix = VerificationReport.managedBlockPrefix
    private let other = "Mainline merge test for `backend`: clean; not a safety claim"
    private let report = VerificationReport(clauses: (1...3).map { index in
        ClauseVerificationRecord(
            issueID: "BACK-1", cid: "c\(index)", level: "card", text: "Clause \(index)", locationID: "epic/story",
            citationProvenance: "machine-found", verdict: .met,
            whatWasChecked: String(repeating: "checked ", count: 40),
            interpretation: String(repeating: "read ", count: 40),
            judgedBy: .agent, invalidatedCause: nil
        )
    })

    private func budget(_ value: Int) throws -> DescriptionBudget {
        try DescriptionBudget(configured: value, limit: limit)
    }

    private func fenced(_ block: String) -> String { ManagedBlockFence.initialDescription(rendered: block) }

    private func write(_ issue: BoardObjectID) -> OutboxWrite {
        OutboxWrite(key: "verification", write: .updateManagedBlockLinesCompacting(
            issue: issue, prefix: prefix, renderings: report.managedBlockRenderings()
        ))
    }

    @Test("Rung 1 over, rung 2 fits: rung 2 is written beside the block's other line and the prose")
    func rungTwoIsWritten() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let board = FakeWritingBoard()
        let rungs = report.managedBlockRenderings()
        let issue = await board.seed(issue: "feature", description: "Operator prose.\n" + fenced("roll-up\n" + other))
        let patched = "roll-up\n" + other + "\n" + rungs[1]
        let expected = "Operator prose.\n" + fenced(patched)
        let outbox = try outbox(journal, board: board, descriptionBudget: try budget(expected.utf16.count))
        let full = "Operator prose.\n" + fenced("roll-up\n" + other + "\n" + rungs[0])
        #expect(full.utf16.count > expected.utf16.count)

        let delivery = try await outbox.post(write(issue))

        #expect(delivery.outcome == .applied(nil))
        #expect(await board.issue(issue)?.description == expected)
        #expect(try journal.managedBlockLastPostedHash(issueID: "feature") == ManagedBlockFence.sha256(patched))
        #expect(await board.comments.isEmpty)
    }

    @Test("A replay onto a block already holding an older report replaces it")
    func replayReplacesTheOlderReport() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let board = FakeWritingBoard()
        let rungs = report.managedBlockRenderings()
        let issue = await board.seed(
            issue: "feature", description: fenced("roll-up\n" + other + "\n" + prefix + "older report line")
        )
        let outbox = try outbox(journal, board: board, descriptionBudget: try budget(10_000))

        _ = try await outbox.post(write(issue))

        let description = try #require(await board.issue(issue)?.description)
        #expect(description == fenced("roll-up\n" + other + "\n" + rungs[0]))
        #expect(!description.contains("older report line"))
        #expect(description.components(separatedBy: prefix + "Definition of Done").count == 2)
    }

    @Test("No rung fits and the report fits alone: untouched, one event, one comment naming the report")
    func operatorTextTakesTheRoom() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let board = FakeWritingBoard()
        let rungs = report.managedBlockRenderings()
        let original = String(repeating: "Operator prose. ", count: 20) + "\n" + fenced("roll-up")
        let issue = await board.seed(issue: "feature", description: original)
        let aloneLength = fenced(rungs[2]).utf16.count
        let outbox = try outbox(journal, board: board, descriptionBudget: try budget(aloneLength + 10))

        let delivery = try await outbox.post(write(issue))

        guard case .aborted = delivery.outcome else {
            Issue.record("expected aborted, got \(delivery.outcome)")
            return
        }
        #expect(await board.issue(issue)?.description == original)
        #expect(await board.updateCalls == 0)
        #expect(try journal.events(ofType: .managedBlockOverBudget).count == 1)
        let comments = await board.comments
        #expect(comments.count == 1)
        let body = try #require(comments.first?.body)
        let composed = (original.utf16.count - "roll-up".utf16.count) + ("roll-up\n" + rungs[2]).utf16.count
        #expect(body.contains(prefix))
        #expect(body.contains("\(composed)"))
        #expect(body.contains("\(aloneLength + 10)"))
        #expect(body.contains("UTF-16 code units"))
        #expect(body.contains("left untouched"))
        #expect(body.contains("leaves too little room"))
        #expect(body.contains("stays in the Journal"))
        #expect(!body.contains("Route id"))
        #expect(!body.contains("lowered"))

        _ = try await outbox.post(write(issue))
        #expect(await board.comments.count == 1)
    }

    @Test("No rung fits and the report does not fit alone: the report is longer than the budget")
    func reportLongerThanBudget() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let board = FakeWritingBoard()
        let rungs = report.managedBlockRenderings()
        let original = fenced("roll-up")
        let issue = await board.seed(issue: "feature", description: original)
        let tooSmall = try budget(fenced(rungs[2]).utf16.count - 1)
        let outbox = try outbox(journal, board: board, descriptionBudget: tooSmall)

        _ = try await outbox.post(write(issue))

        #expect(await board.issue(issue)?.description == original)
        let body = try #require(await board.comments.first?.body)
        #expect(body.contains("The report itself is longer than the budget"))
        #expect(body.contains("Settings › Board connections"))
        #expect(!body.contains("Route id"))
        #expect(!body.contains("lowered"))
        #expect(!body.contains("Operator's own text"))
    }
}
