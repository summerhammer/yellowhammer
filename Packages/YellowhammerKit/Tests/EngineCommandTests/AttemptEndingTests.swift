import Domain
import Foundation
import Testing

// routing/exclude-tried-routes-on-retry (P7.7): the pure ending vocabulary — mapping a failed run onto
// an ending, and the truth table over excludesRoute/consumesAttempt/outcome that the Journal's writes
// depend on.

@Test("A non-zero exit maps to hardFailure(.exitStatus(_))")
func failedRunExitStatusMapsToHardFailure() {
    let ending = AttemptEnding(failedRun: .failed(exitStatus: 2))
    #expect(ending == .hardFailure(.exitStatus(2)))
}

@Test("Each Crashed-Unknown cause maps straight through", arguments: [
    CrashedUnknownCause.resultFile(.empty),
    CrashedUnknownCause.terminated(.aborted(forcedKill: true)),
    CrashedUnknownCause.signaled(15)
])
func failedRunCrashedUnknownMapsThrough(_ cause: CrashedUnknownCause) {
    let ending = AttemptEnding(failedRun: .crashedUnknown(cause))
    #expect(ending == .crashedUnknown(cause))
}

@Test("A completed run maps to nil: its ending is decided later, not by the run")
func failedRunCompletedMapsToNil() {
    let result = DispatchResult.worker(WorkerResult(outcome: .completed(commit: "abc123", summary: "done")))
    let ending = AttemptEnding(failedRun: .completed(result))
    #expect(ending == nil)
}

@Test(
    "excludesRoute is true only for the two capability failures",
    arguments: [
        (AttemptEnding.success, false),
        (AttemptEnding.hardFailure(.exitStatus(1)), true),
        (AttemptEnding.roundsExhausted(rounds: 3), true),
        (AttemptEnding.crashedUnknown(.signaled(9)), false),
        (AttemptEnding.question, false),
        (AttemptEnding.cancelled, false)
    ]
)
func excludesRouteTruthTable(_ ending: AttemptEnding, _ expected: Bool) {
    #expect(ending.excludesRoute == expected)
}

@Test(
    "consumesAttempt is true for every ending but a question or a cancellation",
    arguments: [
        (AttemptEnding.success, true),
        (AttemptEnding.hardFailure(.exitStatus(1)), true),
        (AttemptEnding.roundsExhausted(rounds: 3), true),
        (AttemptEnding.crashedUnknown(.signaled(9)), true),
        (AttemptEnding.question, false),
        (AttemptEnding.cancelled, false)
    ]
)
func consumesAttemptTruthTable(_ ending: AttemptEnding, _ expected: Bool) {
    #expect(ending.consumesAttempt == expected)
}

@Test("outcome.rawValue spells the stored attempt.result vocabulary")
func outcomeRawValueSpellings() {
    #expect(AttemptOutcome.success.rawValue == "success")
    #expect(AttemptOutcome.hardFailure.rawValue == "hard failure")
    #expect(AttemptOutcome.roundsExhausted.rawValue == "rounds-exhausted")
    #expect(AttemptOutcome.crashedUnknown.rawValue == "Crashed-Unknown")
    #expect(AttemptOutcome.question.rawValue == "question")
    #expect(AttemptOutcome.cancelled.rawValue == "cancelled")
}

@Test("exclusionReason is set only for the two capability failures")
func exclusionReasonOnlyForCapabilityFailures() {
    #expect(AttemptEnding.hardFailure(.exitStatus(1)).exclusionReason == "hard failure")
    #expect(AttemptEnding.roundsExhausted(rounds: 1).exclusionReason == "rounds-exhausted")
    #expect(AttemptEnding.success.exclusionReason == nil)
    #expect(AttemptEnding.crashedUnknown(.signaled(9)).exclusionReason == nil)
    #expect(AttemptEnding.question.exclusionReason == nil)
    #expect(AttemptEnding.cancelled.exclusionReason == nil)
}

@Test("A cancellation never yields a FailureCause, like a question or a success")
func cancelledYieldsNoFailureCause() {
    #expect(FailureCause(ending: .cancelled) == nil)
}

@Test("An Operator abort is the fifth outcome: not consumed, no Route excluded, never a failure cause")
func abortedEndingVocabulary() {
    let ending = AttemptEnding.aborted
    #expect(ending.outcome == .aborted)
    #expect(AttemptOutcome.aborted.rawValue == "aborted")
    #expect(ending.consumesAttempt == false)
    #expect(ending.excludesRoute == false)
    #expect(ending.exclusionReason == nil)
    #expect(ending.classification == "aborted by the Operator")
    #expect(ending.consumedHow == "not consumed; route not excluded (stopped by the Operator)")
    #expect(FailureCause(ending: ending) == nil)
}
