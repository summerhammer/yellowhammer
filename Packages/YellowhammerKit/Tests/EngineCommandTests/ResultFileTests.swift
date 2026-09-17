import Domain
import Engine
import Foundation
import Testing

// P7.1: result schema and instruction contract

@Test("Every valid architect and worker rehearsal fixture decodes to the expected outcome")
func architectAndWorkerFixturesDecodeToExpectedOutcome() throws {
    let architectPlanned = try RehearsalResultFixture.architectPlanned.decode()
    guard case .architect(let result) = architectPlanned,
        case .planned(let plan, let affectedPaths) = result.outcome
    else {
        Issue.record("expected architect .planned")
        return
    }
    #expect(!plan.isEmpty)
    #expect(!affectedPaths.isEmpty)

    let architectFailed = try RehearsalResultFixture.architectFailed.decode()
    guard case .architect(let result) = architectFailed, case .failed(let reason) = result.outcome else {
        Issue.record("expected architect .failed")
        return
    }
    #expect(!reason.isEmpty)

    let workerCompleted = try RehearsalResultFixture.workerCompleted.decode()
    guard case .worker(let result) = workerCompleted, case .completed(let commit, let summary) = result.outcome else {
        Issue.record("expected worker .completed")
        return
    }
    #expect(commit.count == 40)
    #expect(!summary.isEmpty)

    let workerQuestion = try RehearsalResultFixture.workerQuestion.decode()
    guard case .worker(let result) = workerQuestion, case .question(let question) = result.outcome else {
        Issue.record("expected worker .question")
        return
    }
    #expect(!question.isEmpty)

    let workerFailed = try RehearsalResultFixture.workerFailed.decode()
    guard case .worker(let result) = workerFailed, case .failed(let reason) = result.outcome else {
        Issue.record("expected worker .failed")
        return
    }
    #expect(!reason.isEmpty)
}

@Test("Every valid reviewer rehearsal fixture decodes to the expected outcome")
func reviewerFixturesDecodeToExpectedOutcome() throws {
    let reviewerApproved = try RehearsalResultFixture.reviewerApproved.decode()
    guard case .reviewer(let result) = reviewerApproved,
        case .approved(let judgedCommit, let summary) = result.outcome
    else {
        Issue.record("expected reviewer .approved")
        return
    }
    #expect(judgedCommit.count == 40)
    #expect(!summary.isEmpty)

    let reviewerChangesRequested = try RehearsalResultFixture.reviewerChangesRequested.decode()
    guard
        case .reviewer(let result) = reviewerChangesRequested,
        case .changesRequested(_, _, let requestedChanges) = result.outcome
    else {
        Issue.record("expected reviewer .changesRequested")
        return
    }
    #expect(!requestedChanges.isEmpty)
}

@Test("An empty result file fails validation as .empty")
func emptyResultFileFailsValidation() throws {
    #expect(throws: ResultFileError.empty) {
        try RehearsalResultFixture.workerEmpty.decode()
    }
}

@Test("A truncated result file fails validation as .malformedJSON")
func malformedResultFileFailsValidation() throws {
    do {
        _ = try RehearsalResultFixture.workerMalformed.decode()
        Issue.record("expected decoding to throw")
    } catch let error as ResultFileError {
        guard case .malformedJSON = error else {
            Issue.record("expected .malformedJSON, got \(error)")
            return
        }
    }
}

@Test("A worker file decoded expecting reviewer fails as .passMismatch")
func passMismatchFailsValidation() throws {
    let data = try RehearsalResultFixture.workerCompleted.data()
    #expect(throws: ResultFileError.passMismatch(expected: .reviewer, found: .worker)) {
        try ResultFile.decode(data, expecting: .reviewer)
    }
}

@Test("An unsupported schema version fails as .unsupportedVersion")
func unsupportedVersionFailsValidation() throws {
    let json = """
        {"schema": "yellowhammer.result.worker", "version": 2, "outcome": "completed", \
        "commit": "\(String(repeating: "a", count: 40))", "summary": "x"}
        """
    let data = try #require(json.data(using: .utf8))
    #expect(throws: ResultFileError.unsupportedVersion(2)) {
        try ResultFile.decode(data, expecting: .worker)
    }
}

@Test("changes_requested with empty requested_changes fails as .invalid")
func changesRequestedWithEmptyRequestedChangesFailsValidation() throws {
    let json = """
        {"schema": "yellowhammer.result.reviewer", "version": 1, "verdict": "changes_requested", \
        "judged_commit": "\(String(repeating: "a", count: 40))", "summary": "x", "requested_changes": []}
        """
    let data = try #require(json.data(using: .utf8))
    #expect(throws: (any Error).self) {
        try ResultFile.decode(data, expecting: .reviewer)
    }
}

@Test("approved with non-empty requested_changes fails as .invalid")
func approvedWithRequestedChangesFailsValidation() throws {
    let json = """
        {"schema": "yellowhammer.result.reviewer", "version": 1, "verdict": "approved", \
        "judged_commit": "\(String(repeating: "a", count: 40))", "summary": "x", \
        "requested_changes": ["fix it"]}
        """
    let data = try #require(json.data(using: .utf8))
    #expect(throws: (any Error).self) {
        try ResultFile.decode(data, expecting: .reviewer)
    }
}

@Test("A 39-character commit fails as .invalid")
func shortCommitFailsValidation() throws {
    let json = """
        {"schema": "yellowhammer.result.worker", "version": 1, "outcome": "completed", \
        "commit": "\(String(repeating: "a", count: 39))", "summary": "x"}
        """
    let data = try #require(json.data(using: .utf8))
    #expect(throws: (any Error).self) {
        try ResultFile.decode(data, expecting: .worker)
    }
}

@Test("Whitespace-only data fails as .empty")
func whitespaceOnlyFailsValidation() throws {
    let data = Data("   \n\t  ".utf8)
    #expect(throws: ResultFileError.empty) {
        try ResultFile.decode(data, expecting: .worker)
    }
}

@Test("An unknown outcome fails as .invalid")
func unknownOutcomeFailsValidation() throws {
    let json = """
        {"schema": "yellowhammer.result.worker", "version": 1, "outcome": "sleeping"}
        """
    let data = try #require(json.data(using: .utf8))
    #expect(throws: (any Error).self) {
        try ResultFile.decode(data, expecting: .worker)
    }
}

@Test("An unknown schema fails as .unknownSchema")
func unknownSchemaFailsValidation() throws {
    let json = """
        {"schema": "yellowhammer.result.mystery", "version": 1, "outcome": "completed"}
        """
    let data = try #require(json.data(using: .utf8))
    #expect(throws: (any Error).self) {
        try ResultFile.decode(data, expecting: .worker)
    }
}

@Test("Every RehearsalResultFixture resolves to an existing file", arguments: RehearsalResultFixture.allCases)
func everyRehearsalFixtureResolvesToExistingFile(_ fixture: RehearsalResultFixture) {
    #expect(FileManager.default.fileExists(atPath: fixture.url.path))
}
