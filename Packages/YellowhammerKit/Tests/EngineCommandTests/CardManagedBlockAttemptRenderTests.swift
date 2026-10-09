import Domain
import Foundation
import Testing

@testable import Engine
@testable import Journal

// P5.6: Managed Block rendering and hash-skip (Cards) — attempt rendering

/// One `checkRan` run as the Journal reads it back; its event id and timestamp are irrelevant here.
private func checkRun(_ result: CheckRunResult, commit: String?, eventID: Int64 = 1) -> CheckRunRecord {
    CheckRunRecord(
        eventID: eventID, attemptID: 1, result: result, exitStatus: nil, output: nil, judgedCommit: commit,
        occurredAt: Date()
    )
}

@Test("A Check that failed and then passed renders the pass, not the stale failure, with the commit it judged")
func renderCheckFailedThenPassed() {
    let record = AttemptRecord(
        id: 1,
        cardID: 1,
        budgetEpoch: 0,
        route: Route(cli: "claude", model: "opus", effort: "high")!,
        classification: nil,
        result: "success",
        consumedHow: nil,
        checkDeclaredNone: false,
        routeSource: nil,
        overridePin: nil,
        startedAt: Date(),
        endedAt: Date(),
        // Only the failed judgement is a Round; the pass leaves none.
        rounds: [
            RoundRecord(
                id: 1, attemptID: 1, lens: .check, verdict: "failed",
                requestedChanges: nil, judgedCommit: "fddeef4", createdAt: Date()
            )
        ],
        preservedRef: nil,
        preservedCommit: nil
    )
    let account = AttemptAccount(
        ordinal: 1, record: record,
        checkRuns: [checkRun(.failed, commit: "fddeef4"), checkRun(.passed, commit: "b763aff", eventID: 2)]
    )

    #expect(account.checkResult == "passed on `b763aff` after 1 failed run")
}

@Test("The Check result words the last run, the judged commit and the earlier failures")
func checkResultWording() {
    let failed = checkRun(.failed, commit: nil)
    let passed = checkRun(.passed, commit: "abc1234")
    let declaredNone = checkRun(.declaredNone, commit: "abc1234")

    #expect(AttemptAccount.checkResult(checkDeclaredNone: false, runs: []) == "not run")
    #expect(AttemptAccount.checkResult(checkDeclaredNone: false, runs: [failed]) == "failed")
    #expect(AttemptAccount.checkResult(checkDeclaredNone: false, runs: [passed]) == "passed on `abc1234`")
    #expect(
        AttemptAccount.checkResult(checkDeclaredNone: false, runs: [failed, failed, passed])
            == "passed on `abc1234` after 2 failed runs"
    )
    // The last run decides: an earlier pass is not a failure to count.
    #expect(AttemptAccount.checkResult(checkDeclaredNone: false, runs: [passed, failed]) == "failed")
    #expect(
        AttemptAccount.checkResult(checkDeclaredNone: false, runs: [failed, failed]) == "failed after 1 failed run"
    )
    let modelAlone = "green came from a model alone (`check = none`)"
    #expect(AttemptAccount.checkResult(checkDeclaredNone: true, runs: []) == modelAlone)
    #expect(AttemptAccount.checkResult(checkDeclaredNone: false, runs: [declaredNone]) == modelAlone)
}

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
    let account = AttemptAccount(
        ordinal: 1, record: record, checkRuns: [checkRun(.failed, commit: nil)]
    )
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
    let account = AttemptAccount(ordinal: 1, record: record, checkRuns: [])
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
    let account = AttemptAccount(ordinal: 1, record: record, checkRuns: [])
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
    let account = AttemptAccount(ordinal: 1, record: record, checkRuns: [])
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
    let account = AttemptAccount(ordinal: 1, record: record, checkRuns: [])
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
