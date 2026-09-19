import Domain
import Foundation
import Testing

@testable import Engine
@testable import Journal

// P5.6: Managed Block rendering and hash-skip (Cards) — attempt rendering

@Test("Attempt with check round renders check result and rounds")
func renderAttemptWithCheckRound() {
    let record = AttemptRecord(
        id: 1,
        cardID: 1,
        budgetEpoch: 0,
        route: Route(cli: "claude", model: "opus", effort: "high")!,
        classification: nil,
        result: "succeeded",
        consumedHow: nil,
        checkDeclaredNone: false,
        routeSource: nil,
        overridePin: nil,
        startedAt: Date(),
        endedAt: Date(),
        rounds: [
            RoundRecord(
                id: 1, attemptID: 1, lens: .check, verdict: "failed",
                requestedChanges: nil, judgedCommit: nil, createdAt: Date()
            )
        ],
        preservedRef: nil,
        preservedCommit: nil
    )
    let account = AttemptAccount(ordinal: 1, record: record)
    let brief = ArchitecturalBrief(prose: "Brief", transcriptions: [])
    let block = CardManagedBlock(
        kind: "impl.boilerplate",
        repository: "backend",
        state: .todo,
        lanePosition: 1,
        laneLength: 1,
        brief: brief,
        definitionOfDone: [],
        attempts: [account]
    )

    let rendered = block.render()

    #expect(rendered.contains("#### Attempt 1 — `claude/opus/high`"))
    #expect(rendered.contains("- Check: failed"))
    #expect(rendered.contains("- Rounds: 1. check — failed"))
    #expect(rendered.contains("- Outcome: succeeded"))
}

@Test("Check declared none renders check result")
func renderCheckDeclaredNone() {
    let record = AttemptRecord(
        id: 1,
        cardID: 1,
        budgetEpoch: 0,
        route: Route(cli: "claude", model: "opus", effort: "high")!,
        classification: nil,
        result: "succeeded",
        consumedHow: nil,
        checkDeclaredNone: true,
        routeSource: nil,
        overridePin: nil,
        startedAt: Date(),
        endedAt: Date(),
        rounds: [],
        preservedRef: nil,
        preservedCommit: nil
    )
    let account = AttemptAccount(ordinal: 1, record: record)
    let brief = ArchitecturalBrief(prose: "Brief", transcriptions: [])
    let block = CardManagedBlock(
        kind: "impl.boilerplate",
        repository: "backend",
        state: .todo,
        lanePosition: 1,
        laneLength: 1,
        brief: brief,
        definitionOfDone: [],
        attempts: [account]
    )

    let rendered = block.render()

    let expectedCheck = "- Check: green came from a model alone (`check = none`)"
    #expect(rendered.contains(expectedCheck))
}

@Test("Open attempt renders in progress outcome")
func renderOpenAttempt() {
    let record = AttemptRecord(
        id: 1,
        cardID: 1,
        budgetEpoch: 0,
        route: Route(cli: "claude", model: "opus", effort: "high")!,
        classification: nil,
        result: nil,
        consumedHow: nil,
        checkDeclaredNone: false,
        routeSource: nil,
        overridePin: nil,
        startedAt: Date(),
        endedAt: nil,
        rounds: [],
        preservedRef: nil,
        preservedCommit: nil
    )
    let account = AttemptAccount(ordinal: 1, record: record)
    let brief = ArchitecturalBrief(prose: "Brief", transcriptions: [])
    let block = CardManagedBlock(
        kind: "impl.boilerplate",
        repository: "backend",
        state: .todo,
        lanePosition: 1,
        laneLength: 1,
        brief: brief,
        definitionOfDone: [],
        attempts: [account]
    )

    let rendered = block.render()

    #expect(rendered.contains("- Outcome: in progress"))
}

@Test("Consumed field appears when set")
func renderConsumed() {
    let record = AttemptRecord(
        id: 1,
        cardID: 1,
        budgetEpoch: 0,
        route: Route(cli: "claude", model: "opus", effort: "high")!,
        classification: nil,
        result: "succeeded",
        consumedHow: "some reason",
        checkDeclaredNone: false,
        routeSource: nil,
        overridePin: nil,
        startedAt: Date(),
        endedAt: Date(),
        rounds: [],
        preservedRef: nil,
        preservedCommit: nil
    )
    let account = AttemptAccount(ordinal: 1, record: record)
    let brief = ArchitecturalBrief(prose: "Brief", transcriptions: [])
    let block = CardManagedBlock(
        kind: "impl.boilerplate",
        repository: "backend",
        state: .todo,
        lanePosition: 1,
        laneLength: 1,
        brief: brief,
        definitionOfDone: [],
        attempts: [account]
    )

    let rendered = block.render()

    #expect(rendered.contains("- Consumed: some reason"))
}

@Test("Multiple rounds render with all lenses and verdicts")
func renderMultipleRounds() {
    let record = AttemptRecord(
        id: 1,
        cardID: 1,
        budgetEpoch: 0,
        route: Route(cli: "claude", model: "opus", effort: "high")!,
        classification: nil,
        result: "succeeded",
        consumedHow: nil,
        checkDeclaredNone: false,
        routeSource: nil,
        overridePin: nil,
        startedAt: Date(),
        endedAt: Date(),
        rounds: [
            RoundRecord(
                id: 1, attemptID: 1, lens: .review, verdict: "changes requested",
                requestedChanges: nil, judgedCommit: nil, createdAt: Date()
            ),
            RoundRecord(
                id: 2, attemptID: 1, lens: .check, verdict: "failed",
                requestedChanges: nil, judgedCommit: nil, createdAt: Date()
            )
        ],
        preservedRef: nil,
        preservedCommit: nil
    )
    let account = AttemptAccount(ordinal: 1, record: record)
    let brief = ArchitecturalBrief(prose: "Brief", transcriptions: [])
    let block = CardManagedBlock(
        kind: "impl.boilerplate",
        repository: "backend",
        state: .todo,
        lanePosition: 1,
        laneLength: 1,
        brief: brief,
        definitionOfDone: [],
        attempts: [account]
    )

    let rendered = block.render()

    let expectedRounds = "- Rounds: 1. review — changes requested; 2. check — failed"
    #expect(rendered.contains(expectedRounds))
}
