import Domain
import Engine
import Foundation
import Testing

// P7.2: process lifecycle — the pure dual-key classification, over already-read bytes.

private let validWorkerJSON = Data(
    """
    {"schema":"yellowhammer.result.worker","version":1,"outcome":"completed",\
    "commit":"0123456789abcdef0123456789abcdef01234567","summary":"stub"}
    """.utf8
)

private let validArchitectJSON = Data(
    """
    {"schema":"yellowhammer.result.architect","version":1,"outcome":"planned",\
    "plan":"do the thing","affected_paths":["a.swift"]}
    """.utf8
)

@Test("Exit 0 with a valid, matching result file completes")
func exitZeroWithValidFileCompletes() {
    let outcome = RunOutcome.classify(end: .exited(status: 0), resultFile: validWorkerJSON, pass: .worker)
    guard case .completed(.worker(let result)) = outcome, case .completed = result.outcome else {
        Issue.record("expected .completed(.worker(_)), got \(outcome)")
        return
    }
}

@Test("Exit 0 with no bytes at all is Crashed-Unknown, unreadable")
func exitZeroNilDataIsCrashedUnknownUnreadable() {
    let outcome = RunOutcome.classify(end: .exited(status: 0), resultFile: nil, pass: .worker)
    #expect(outcome == .crashedUnknown(.resultFile(.unreadable("result file not found"))))
}

@Test("Exit 0 with whitespace-only bytes is Crashed-Unknown, empty")
func exitZeroWhitespaceIsCrashedUnknownEmpty() {
    let outcome = RunOutcome.classify(end: .exited(status: 0), resultFile: Data("   \n".utf8), pass: .worker)
    #expect(outcome == .crashedUnknown(.resultFile(.empty)))
}

@Test("Exit 0 with a valid file for the wrong pass is Crashed-Unknown, pass mismatch")
func exitZeroWrongPassIsCrashedUnknownPassMismatch() {
    let outcome = RunOutcome.classify(end: .exited(status: 0), resultFile: validArchitectJSON, pass: .worker)
    #expect(outcome == .crashedUnknown(.resultFile(.passMismatch(expected: .worker, found: .architect))))
}

@Test("A non-zero exit is attributable to the CLI even with a valid file present")
func nonZeroExitIsAttributableToCLI() {
    let outcome = RunOutcome.classify(end: .exited(status: 1), resultFile: validWorkerJSON, pass: .worker)
    #expect(outcome == .failed(exitStatus: 1))
}

@Test("A foreign signal is Crashed-Unknown, signaled")
func signaledIsCrashedUnknownSignaled() {
    let outcome = RunOutcome.classify(end: .signaled(15), resultFile: validWorkerJSON, pass: .worker)
    #expect(outcome == .crashedUnknown(.signaled(15)))
}

@Test("A timeout is Crashed-Unknown, terminated, regardless of a valid file present")
func timedOutIsCrashedUnknownTerminated() {
    let end = RunEnd.timedOut(after: .seconds(30), forcedKill: true)
    let outcome = RunOutcome.classify(end: end, resultFile: validWorkerJSON, pass: .worker)
    #expect(outcome == .crashedUnknown(.terminated(end)))
}

@Test("An abort is Crashed-Unknown, terminated, regardless of a valid file present")
func abortedIsCrashedUnknownTerminated() {
    let end = RunEnd.aborted(forcedKill: false)
    let outcome = RunOutcome.classify(end: end, resultFile: validWorkerJSON, pass: .worker)
    #expect(outcome == .crashedUnknown(.terminated(end)))
}
