import Domain
import Foundation
import GRDB
import Testing

@testable import Engine
@testable import Journal

// board-projection/write-board-updates-through-the-outbox: the authoring transaction cannot leave a
// partial board — either the Feature Issue and all of its Cards exist, or none of them do.

@Suite("Outbox: groups")
struct OutboxGroupTests {
    // MARK: - Groups

    @Test("A forced mid-transaction failure leaves no partial board: applied creates are archived")
    func groupFailureLeavesNoPartialBoard() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let board = FakeWritingBoard()
        let adopted = await board.seed(issue: "adopted-card", description: nil)
        await board.script(.refuse(.refused("Linear reports the title is invalid")), for: "Card two")
        let outbox = try outbox(journal, board: board)

        _ = try outbox.acceptGroup([
            OutboxWrite(key: "feature:1:create", write: card("Feature one")),
            OutboxWrite(key: "card:1:main:1:create", write: card("Card one", parentKey: "feature:1:create")),
            OutboxWrite(
                key: "adopt:adopted-card",
                write: .updateIssue(
                    issue: adopted,
                    change: BoardIssueChange(parent: .set(BoardObjectID(rawValue: "issue-1"))),
                    undo: BoardIssueChange(parent: .clear)
                )
            ),
            OutboxWrite(key: "card:1:main:2:create", write: card("Card two", parentKey: "feature:1:create")),
            OutboxWrite(key: "card:1:main:3:create", write: card("Card three", parentKey: "feature:1:create"))
        ], key: "authoring:1")
        let report = try await outbox.deliverPending()

        #expect(report.failed.count == 1)
        #expect(await board.liveIssues.map(\.title) == ["adopted-card"])
        #expect(await board.archivedIssues.map(\.title).sorted() == ["Card one", "Feature one"])
        #expect(await board.issue(adopted)?.parent == nil)
        let states = try journal.outboxEntries(groupID: "authoring:1").map(\.state)
        #expect(states == [.applied, .applied, .applied, .failed, .aborted])
        #expect(try journal.pendingOutboxEntries().isEmpty)
        #expect(try journal.events(ofType: .outboxGroupRolledBack).count == 1)
    }

    @Test("A group interrupted by a crash is completed on replay, with Cards nested under the Feature Issue")
    func groupCompletesOnReplay() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let board = FakeWritingBoard()
        let clock = ManualClock()
        let group = [
            OutboxWrite(key: "feature:1:create", write: card("Feature one")),
            OutboxWrite(key: "card:1:main:1:create", write: card("Card one", parentKey: "feature:1:create")),
            OutboxWrite(key: "card:1:web:1:create", write: card("Card two", parentKey: "feature:1:create"))
        ]

        let killed = try outbox(journal, board: board, runID: RunID(), clock: clock) { _ in throw SimulatedCrash() }
        _ = try killed.acceptGroup(group, key: "authoring:1")
        await #expect(throws: SimulatedCrash.self) { try await killed.deliverPending() }
        #expect(await board.liveIssues.map(\.title) == ["Feature one"])

        clock.advance(by: 700)
        let resumed = try outbox(journal, board: board, runID: RunID(), clock: clock)
        let report = try await resumed.deliverPending()

        #expect(report.applied.count == 3)
        let live = await board.liveIssues
        #expect(live.map(\.title) == ["Feature one", "Card one", "Card two"])
        #expect(live.dropFirst().allSatisfy { $0.parent == live.first?.id })
        #expect(try journal.outboxEntries(groupID: "authoring:1").allSatisfy { $0.state == .applied })
    }

    @Test("Writes are delivered in accepted order across runs, and an applied write is never applied twice")
    func deliveryOrderAndNoDoubleApply() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let board = FakeWritingBoard()
        let outbox = try outbox(journal, board: board)
        let issue = await board.seed(issue: "issue-1", description: nil)

        _ = try await outbox.post(OutboxWrite(key: "a", write: .createComment(issue: issue, body: "first")))
        _ = try await outbox.post(OutboxWrite(key: "b", write: .createComment(issue: issue, body: "second")))
        let again = try await outbox.deliverPending()

        #expect(again.deliveries.isEmpty)
        #expect(await board.comments.map(\.body) == ["first", "second"])
        #expect(await board.createCommentCalls == 2)
    }
}
