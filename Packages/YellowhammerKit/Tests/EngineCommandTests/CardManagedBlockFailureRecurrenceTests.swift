import Domain
@testable import Engine
import Foundation
import Testing

// loop-state/record-failure-cause-recurrence (roadmap P8.8; OQ127): a Card Blocked under `failure
// recurrence` names the recurring cause and how many Nights met it in its Managed Block. Triage is the
// Operator's morning only, so nothing here says it.

private func block(recurrence: FailureRecurrence?, blockReason: BlockReason) -> CardManagedBlock {
    CardManagedBlock(
        kind: "impl", repository: "backend", state: .blocked, blockReason: blockReason.rawValue,
        lanePosition: 1, laneLength: 1, brief: ArchitecturalBrief(prose: "", transcriptions: []),
        definitionOfDone: [], attempts: [], failureRecurrence: recurrence
    )
}

@Test("A Card Blocked on failure recurrence names the cause and the Night count, right under its State")
func recurrenceRendersUnderTheState() throws {
    let rendered = block(
        recurrence: FailureRecurrence(cause: "hard failure (exit status 2)", nights: 2),
        blockReason: .failureRecurrence
    ).render()
    let lines = rendered.components(separatedBy: "\n")

    let state = try #require(lines.firstIndex(of: "**State:** Blocked — failure recurrence"))
    #expect(lines[state + 1] == "**Failure-Cause Recurrence:** failure cause `hard failure (exit status 2)` " +
        "recurred across 2 Nights — a design conversation, not a rerun")
    #expect(!rendered.contains("Triage"))
}

@Test("A Card Blocked on a first occurrence carries no recurrence line")
func firstOccurrenceRendersNoRecurrence() {
    #expect(!block(recurrence: nil, blockReason: .hardFailure).render().contains("Failure-Cause Recurrence"))
}
