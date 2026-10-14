import Domain
import Foundation
import Testing

@testable import Engine
@testable import Journal

// board-projection/maintain-the-managed-block, "budget on rewrite": a Managed Block rewrite is measured over
// the WHOLE description after the fence replace. Over budget it takes the first rendering of the ladder that
// fits; when none does it is refused as a broken delimiter is.

@Suite("Outbox: description budget on a Managed Block rewrite")
struct OutboxDescriptionBudgetTests {
    /// A board that counts UTF-16 code units, with a ceiling far above any budget these tests use.
    private let limit = BoardDescriptionLimit(maximum: 100_000, unit: .utf16CodeUnits)

    private func budget(_ value: Int) throws -> DescriptionBudget {
        try DescriptionBudget(configured: value, limit: limit)
    }

    /// The fence itself costs 50 units, so a description of `initialDescription(rendered: r)` is `50 + r`.
    private func description(_ rendered: String) -> String {
        ManagedBlockFence.initialDescription(rendered: rendered)
    }

    private let long = String(repeating: "full ", count: 40)
    private let medium = String(repeating: "mid ", count: 10)
    private let short = "short"

    @Test("The full rendering fits: it is posted as it is, and its hash is recorded")
    func fullRenderingFits() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let board = FakeWritingBoard()
        let issue = await board.seed(issue: "issue-1", description: description("old"))
        let outbox = try outbox(journal, board: board, descriptionBudget: try budget(500))

        let delivery = try await outbox.post(OutboxWrite(
            key: "block:issue-1", write: .rewriteManagedBlockCompacting(issue: issue, renderings: [long, medium, short])
        ))

        #expect(delivery.outcome == .applied(nil))
        #expect(await board.issue(issue)?.description == description(long))
        #expect(try journal.managedBlockLastPostedHash(issueID: "issue-1") == ManagedBlockFence.sha256(long))
    }

    @Test("A later rung that fits is posted, and the hash recorded is that rung's")
    func laterRungFits() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let board = FakeWritingBoard()
        let issue = await board.seed(issue: "issue-1", description: "Operator prose.\n" + description("old"))
        // 50 (fence) + 16 (prose) + 40 (medium) = 106 fits; 66 + 200 (long) does not.
        let outbox = try outbox(journal, board: board, descriptionBudget: try budget(120))

        let delivery = try await outbox.post(OutboxWrite(
            key: "block:issue-1", write: .rewriteManagedBlockCompacting(issue: issue, renderings: [long, medium, short])
        ))

        #expect(delivery.outcome == .applied(nil))
        #expect(await board.issue(issue)?.description == "Operator prose.\n" + description(medium))
        #expect(try journal.managedBlockLastPostedHash(issueID: "issue-1") == ManagedBlockFence.sha256(medium))
        #expect(try journal.events(ofType: .managedBlockWritten).map(\.event).count == 1)
        #expect(await board.comments.isEmpty)
    }

    @Test("Operator text outside the fence keeps every rung over: refused, event appended, one comment")
    func everyRungOverIsRefused() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let board = FakeWritingBoard()
        let prose = String(repeating: "Operator prose. ", count: 20)
        let original = prose + "\n" + description("old")
        let issue = await board.seed(issue: "issue-1", description: original)
        let outbox = try outbox(journal, board: board, descriptionBudget: try budget(200))
        let write = OutboxWrite(
            key: "block:issue-1", write: .rewriteManagedBlockCompacting(issue: issue, renderings: [long, medium, short])
        )

        let delivery = try await outbox.post(write)

        guard case .aborted = delivery.outcome else {
            Issue.record("expected aborted, got \(delivery.outcome)")
            return
        }
        #expect(await board.issue(issue)?.description == original)
        #expect(await board.updateCalls == 0)
        let composed = original.utf16.count - 3 + short.utf16.count  // "old" replaced by "short"
        #expect(try journal.events(ofType: .managedBlockOverBudget).map(\.event) == [
            .managedBlockOverBudget(issueID: "issue-1", length: composed, budget: 200)
        ])
        #expect(try journal.managedBlockLastPostedHash(issueID: "issue-1") == nil)
        let comments = await board.comments
        #expect(comments.count == 1)
        let body = try #require(comments.first?.body)
        #expect(body.contains("\(composed)"))
        #expect(body.contains("200"))
        #expect(body.contains("UTF-16 code units"))
        // The Managed Block alone fits, so the cause named is the Operator's text.
        #expect(body.contains("Definition of Done"))
        #expect(!body.contains("Route id"))

        // The same write again posts no second diagnostic.
        _ = try await outbox.post(write)
        #expect(await board.comments.count == 1)
    }

    @Test("A rendering that cannot fit even alone names a lowered budget or a longer Route id")
    func renderingAloneOverNamesBudgetOrRoute() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let board = FakeWritingBoard()
        let original = description("old")
        let issue = await board.seed(issue: "issue-1", description: original)
        let outbox = try outbox(journal, board: board, descriptionBudget: try budget(60))

        let delivery = try await outbox.post(OutboxWrite(
            key: "block:issue-1", write: .rewriteManagedBlockCompacting(issue: issue, renderings: [long, medium])
        ))

        guard case .aborted = delivery.outcome else {
            Issue.record("expected aborted, got \(delivery.outcome)")
            return
        }
        #expect(await board.issue(issue)?.description == original)
        let body = try #require(await board.comments.first?.body)
        #expect(body.contains("description budget lowered"))
        #expect(body.contains("longer Route id"))
    }

    @Test("A plain rewrite and a targeted line update have no ladder: over budget they are refused")
    func singleRenderingWritesAreRefused() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let board = FakeWritingBoard()
        let original = description("old")
        let issue = await board.seed(issue: "issue-1", description: original)
        let outbox = try outbox(journal, board: board, descriptionBudget: try budget(80))

        let rewrite = try await outbox.post(OutboxWrite(
            key: "rewrite", write: .rewriteManagedBlock(issue: issue, rendered: long)
        ))
        let line = try await outbox.post(OutboxWrite(
            key: "line", write: .updateManagedBlockLine(issue: issue, prefix: "Report: ", line: "Report: " + long)
        ))

        for delivery in [rewrite, line] {
            guard case .aborted = delivery.outcome else {
                Issue.record("expected aborted, got \(delivery.outcome)")
                return
            }
        }
        #expect(await board.issue(issue)?.description == original)
        #expect(try journal.events(ofType: .managedBlockOverBudget).count == 2)
    }

    @Test("With no budget nothing is checked: the full rendering is posted however long")
    func noBudgetIsUnchanged() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let board = FakeWritingBoard()
        let issue = await board.seed(issue: "issue-1", description: description("old"))
        let outbox = try outbox(journal, board: board)
        let huge = String(repeating: "x", count: 50_000)

        let delivery = try await outbox.post(OutboxWrite(
            key: "block:issue-1", write: .rewriteManagedBlockCompacting(issue: issue, renderings: [huge, short])
        ))

        #expect(delivery.outcome == .applied(nil))
        #expect(await board.issue(issue)?.description == description(huge))
        #expect(try journal.events(ofType: .managedBlockOverBudget).isEmpty)
    }

    @Test("Length is measured in UTF-16 code units: an emoji-heavy rung that fits by character count is over")
    func measuredInUTF16() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let board = FakeWritingBoard()
        let issue = await board.seed(issue: "issue-1", description: description("old"))
        // 20 parrots are 20 characters but 40 code units: 50 + 40 = 90 > 80, while by character count 70 fits.
        let parrots = String(repeating: "🦜", count: 20)
        let outbox = try outbox(journal, board: board, descriptionBudget: try budget(80))

        let delivery = try await outbox.post(OutboxWrite(
            key: "block:issue-1", write: .rewriteManagedBlockCompacting(issue: issue, renderings: [parrots, short])
        ))

        #expect(delivery.outcome == .applied(nil))
        #expect(await board.issue(issue)?.description == description(short))
        #expect(parrots.count + 50 <= 80)
        #expect(parrots.utf16.count + 50 > 80)
    }
}
