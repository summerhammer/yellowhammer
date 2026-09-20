import Domain
@testable import Engine
import Foundation
import GRDB
@testable import Journal
import Testing

// roadmap P9.4 (spec: feature-authoring/author-the-cycle-and-card-dag, second story, as far as "adoption
// is part of the same atomic transaction"): an adopted Blocked Card is re-parented on the board and moves
// into the new Cycle, keeping its counters, state and Block Reason; a failed transaction restores it.

@Suite("Authoring transaction: adoption (P9.4)")
struct AuthoringTransactionAdoptionTests {
    private struct Adopted {
        let oldFeature: BoardObjectID
        let card: BoardObjectID
        let cardRowID: Int64
    }

    /// A Blocked Card in an archived Cycle, with spent counters, whose board issue hangs under the old
    /// Feature Issue.
    private func seedAdoptedCard(_ rig: AuthoringRig) async throws -> Adopted {
        let oldFeature = await rig.boards.writing.seed(issue: "FEAT-OLD", description: nil)
        let card = await rig.boards.writing.seed(issue: "CARD-OLD", description: nil)
        _ = try await rig.boards.writing.updateIssue(card, BoardIssueChange(parent: .set(oldFeature)))
        let (_, cycleID) = try insertFeatureSelectionAdoptionFixture(rig.journal, closedFeatureIssueID: "FEAT-OLD")
        let rowID = try insertFeatureSelectionAdoptionCard(
            rig.journal, cycleID: cycleID, issueID: "CARD-OLD", repository: "backend", order: 3
        )
        try rig.journal.write { db in
            try db.execute(
                sql: """
                UPDATE card SET failed_adoptions = 2, unanswered_nights = 1, budget_epoch = 4,
                block_reason = 'unanswered' WHERE id = ?
                """,
                arguments: [rowID]
            )
        }
        return Adopted(oldFeature: oldFeature, card: card, cardRowID: rowID)
    }

    @Test("An adopted Card is re-parented, moves into the new Cycle at the head of its lane, and keeps its history")
    func adoptionMovesTheCard() async throws {
        let rig = try await AuthoringRig(adopting: ["CARD-OLD"])
        let adopted = try await seedAdoptedCard(rig)
        let before = try rig.journal.card(id: adopted.cardRowID)

        let outcome = try await rig.run(rig.context())

        #expect(outcome == .authored)
        let live = await rig.boards.writing.liveIssues
        let feature = try #require(live.first { $0.title == "FEAT-1" })
        #expect(await rig.boards.writing.issue(adopted.card)?.parent == feature.id)
        // No replacement Card: the three authored Cards plus the adopted one.
        #expect(live.filter { $0.parent == feature.id }.count == 4)

        let after = try rig.journal.card(id: adopted.cardRowID)
        let (_, cycleID) = try #require(try rig.journal.inFlightFeature())
        #expect(after.cycleID == cycleID)
        #expect(after.authoredOrder == 1)
        #expect(after.state == before.state && after.blockReason == before.blockReason)
        #expect(after.budgetEpoch == 4)
        let counters = try rig.journal.read { db in
            try Row.fetchOne(
                db, sql: "SELECT failed_adoptions, unanswered_nights FROM card WHERE id = ?",
                arguments: [adopted.cardRowID]
            )
        }
        #expect(counters?["failed_adoptions"] == 2 && counters?["unanswered_nights"] == 1)

        let lane = try cardRows(rig.journal).filter { $0.repository == "backend" }
        #expect(lane.map(\.authoredOrder) == [1, 2, 3])
        #expect(lane.first?.issueID == "CARD-OLD")
        #expect(try tableRowCount(rig.journal, table: "card") == 4)
    }

    @Test("A failed transaction restores the adopted Card's parent and leaves its row untouched")
    func failedAdoptionIsRolledBack() async throws {
        let rig = try await AuthoringRig(adopting: ["CARD-OLD"])
        let adopted = try await seedAdoptedCard(rig)
        let before = try rig.journal.card(id: adopted.cardRowID)
        await rig.boards.writing.script(.refuse(.refused("no")), for: "Backend one")

        let outcome = try await rig.run(rig.context())

        #expect(outcome == .authoringRolledBack)
        #expect(await rig.boards.writing.issue(adopted.card)?.parent == adopted.oldFeature)
        #expect(try rig.journal.card(id: adopted.cardRowID) == before)
        #expect(try tableRowCount(rig.journal, table: "feature") == 1)
        #expect(try tableRowCount(rig.journal, table: "cycle") == 1)
        #expect(try tableRowCount(rig.journal, table: "card") == 1)
        #expect(try rig.journal.events(ofType: .featureAuthoringFailed).count == 1)
    }
}
