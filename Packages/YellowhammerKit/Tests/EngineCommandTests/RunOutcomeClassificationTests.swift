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

@Test("Exit 0 with a valid file for the wrong pass is a contract violation, pass mismatch")
func exitZeroWrongPassIsContractViolationPassMismatch() {
    let outcome = RunOutcome.classify(end: .exited(status: 0), resultFile: validArchitectJSON, pass: .worker)
    #expect(outcome == .contractViolation(.passMismatch(expected: .worker, found: .architect)))
}

private func workerFile(_ fields: String) -> Data {
    Data("{\"schema\":\"yellowhammer.result.worker\",\"version\":1,\(fields)}".utf8)
}

@Test("Exit 0 with a completed worker whose commit is null is a contract violation (#445)")
func exitZeroCompletedWithNullCommitIsContractViolation() {
    let data = workerFile(#""outcome":"completed","commit":null,"summary":"stub""#)
    let outcome = RunOutcome.classify(end: .exited(status: 0), resultFile: data, pass: .worker)
    #expect(outcome == .contractViolation(.completedWithoutCommit))
}

@Test("Exit 0 with a completed worker that has no commit key is a contract violation (#445)")
func exitZeroCompletedWithoutCommitKeyIsContractViolation() {
    let data = workerFile(#""outcome":"completed","summary":"stub""#)
    let outcome = RunOutcome.classify(end: .exited(status: 0), resultFile: data, pass: .worker)
    #expect(outcome == .contractViolation(.completedWithoutCommit))
}

@Test("Exit 0 with a completed worker whose commit is not a SHA is a contract violation, invalid commit")
func exitZeroCompletedWithBadCommitIsContractViolationInvalid() {
    let data = workerFile(#""outcome":"completed","commit":"xyz","summary":"stub""#)
    let outcome = RunOutcome.classify(end: .exited(status: 0), resultFile: data, pass: .worker)
    guard case .contractViolation(.invalid(let field, _)) = outcome else {
        Issue.record("expected .contractViolation(.invalid), got \(outcome)")
        return
    }
    #expect(field == "commit")
}

@Test("Exit 0 with a commit that is present but not a string is a contract violation, invalid commit")
func exitZeroCompletedWithNonStringCommitIsContractViolationInvalid() {
    let data = workerFile(#""outcome":"completed","commit":42,"summary":"stub""#)
    let outcome = RunOutcome.classify(end: .exited(status: 0), resultFile: data, pass: .worker)
    guard case .contractViolation(.invalid(let field, _)) = outcome else {
        Issue.record("expected .contractViolation(.invalid), got \(outcome)")
        return
    }
    #expect(field == "commit")
}

@Test("Exit 0 with an unsupported schema version is a contract violation")
func exitZeroUnsupportedVersionIsContractViolation() {
    let data = Data(#"{"schema":"yellowhammer.result.worker","version":2,"outcome":"failed","reason":"x"}"#.utf8)
    let outcome = RunOutcome.classify(end: .exited(status: 0), resultFile: data, pass: .worker)
    #expect(outcome == .contractViolation(.unsupportedVersion(2)))
}

@Test("Exit 0 with malformed JSON stays Crashed-Unknown")
func exitZeroMalformedJSONStaysCrashedUnknown() {
    let data = Data(#"{"schema":"yell"#.utf8)
    let outcome = RunOutcome.classify(end: .exited(status: 0), resultFile: data, pass: .worker)
    guard case .crashedUnknown(.resultFile(.malformedJSON)) = outcome else {
        Issue.record("expected .crashedUnknown(.resultFile(.malformedJSON)), got \(outcome)")
        return
    }
}

@Test("Exit 0 with an unrecognised schema stays Crashed-Unknown")
func exitZeroUnknownSchemaStaysCrashedUnknown() {
    let outcome = RunOutcome.classify(
        end: .exited(status: 0), resultFile: Data(#"{"schema":"something.else","version":1}"#.utf8), pass: .worker
    )
    guard case .crashedUnknown(.resultFile(.unknownSchema)) = outcome else {
        Issue.record("expected .crashedUnknown(.resultFile(.unknownSchema)), got \(outcome)")
        return
    }
}

@Test("A non-zero exit never reads the file: a contract-violating file is still just failed")
func nonZeroExitIgnoresContractViolatingFile() {
    let data = workerFile(#""outcome":"completed","commit":null,"summary":"stub""#)
    let outcome = RunOutcome.classify(end: .exited(status: 1), resultFile: data, pass: .worker)
    #expect(outcome == .failed(exitStatus: 1))
}

@Test("Only the four contract-breaking ResultFileError cases are contract violations")
func isContractViolationTruthTable() {
    #expect(ResultFileError.completedWithoutCommit.isContractViolation)
    #expect(ResultFileError.passMismatch(expected: .worker, found: .architect).isContractViolation)
    #expect(ResultFileError.unsupportedVersion(2).isContractViolation)
    #expect(ResultFileError.invalid(field: "commit", reason: "x").isContractViolation)
    #expect(!ResultFileError.empty.isContractViolation)
    #expect(!ResultFileError.malformedJSON("x").isContractViolation)
    #expect(!ResultFileError.unknownSchema("x").isContractViolation)
    #expect(!ResultFileError.unreadable("x").isContractViolation)
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

@Test("A timeout is a timed-out hard failure, regardless of a valid file present (#507)")
func timedOutIsTimedOut() {
    let end = RunEnd.timedOut(after: .seconds(30), forcedKill: true)
    let outcome = RunOutcome.classify(end: end, resultFile: validWorkerJSON, pass: .worker)
    #expect(outcome == .timedOut(after: .seconds(30)))
    #expect(AttemptEnding(failedRun: outcome) == .hardFailure(.timedOut(after: .seconds(30))))
}

@Test("An abort is Crashed-Unknown, terminated, regardless of a valid file present")
func abortedIsCrashedUnknownTerminated() {
    let end = RunEnd.aborted(forcedKill: false)
    let outcome = RunOutcome.classify(end: end, resultFile: validWorkerJSON, pass: .worker)
    #expect(outcome == .crashedUnknown(.terminated(end)))
}
