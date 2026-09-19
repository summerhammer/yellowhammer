import Domain
@testable import Engine
import Foundation
import Testing

// loop-state/record-failure-cause-recurrence (roadmap P8.8): the Card's board projection shows that it
// was promoted to Triage, and why.

private func block(promotion: TriagePromotion?) -> CardManagedBlock {
    CardManagedBlock(
        kind: "impl", repository: "backend", state: .blocked, blockReason: BlockReason.hardFailure.rawValue,
        lanePosition: 1, laneLength: 1, brief: ArchitecturalBrief(prose: "", transcriptions: []),
        definitionOfDone: [], attempts: [], triagePromotion: promotion
    )
}

@Test("A promoted Card's block names the promotion and its reason, right under its State")
func promotionRendersUnderTheState() throws {
    let lines = block(promotion: TriagePromotion(cause: "hard failure (exit status 2)", nights: 2))
        .render().components(separatedBy: "\n")

    let state = try #require(lines.firstIndex(of: "**State:** Blocked — hard failure"))
    #expect(lines[state + 1] == "**Promoted to Triage:** failure cause `hard failure (exit status 2)` " +
        "recurred across 2 Nights — a design conversation, not a rerun")
}

@Test("A Card Blocked on a first occurrence carries no promotion line")
func firstOccurrenceRendersNoPromotion() {
    #expect(!block(promotion: nil).render().contains("Promoted to Triage"))
}
