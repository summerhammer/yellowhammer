import Domain
@testable import EngineCommand
import Foundation
@testable import Journal
import Testing

// `yh abort` (P18.11): the request is recorded for the one named Attempt only, before any output.

private let abortRoute = Route(cli: "claude", model: "opus", effort: "high")!

private struct AbortWorld {
    let journal: JournalStore
    let runID: RunID
    let cycleID: Int64

    func card(_ issueID: String) throws -> Int64 {
        try insertReconcilerCard(journal, cycleID: cycleID, issueID: issueID, repository: "backend", state: .inProgress)
    }

    func attempt(_ cardID: Int64) throws -> AttemptRecord {
        try journal.recordAttempt(cardID: cardID, route: abortRoute, runID: runID)
    }
}

private func makeAbortWorld(_ journal: JournalStore, feature: String) throws -> AbortWorld {
    let runID = RunID()
    _ = try journal.claimActLease(act: .build, runID: runID, mode: .rehearsal)
    let featureID = try insertReconcilerFeature(journal, issueID: feature)
    let cycleID = try insertReconcilerCycle(journal, featureID: featureID)
    return AbortWorld(journal: journal, runID: runID, cycleID: cycleID)
}

private func abortRequestRows(_ journal: JournalStore) throws -> Int {
    try journal.read { database in try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM operator_abort_request") ?? 0 }
}

private func abort(
    _ journal: JournalStore, attempt: Int64, project: String = "alpha", wait: Duration = .zero,
    output: RecordingOutput
) async throws {
    let attemptAbort = AttemptAbort(
        projectID: try #require(ProjectID(rawValue: project)), attemptID: attempt,
        output: { output.record($0) }, poll: .milliseconds(20), wait: wait
    )
    try await attemptAbort.run(journal: journal)
}

@Suite("yh abort: AttemptAbort")
struct AttemptAbortTests {
    @Test("Only the named Attempt is requested; another running Attempt of the Project is not")
    func requestsExactlyTheNamedAttempt() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try makeAbortWorld(try fixture.open(), feature: "A-F")
        let first = try world.attempt(try world.card("A-1"))
        let second = try world.attempt(try world.card("A-2"))
        let output = RecordingOutput()

        try await abort(world.journal, attempt: first.id, output: output)

        #expect(try world.journal.isOperatorAbortRequested(attemptID: first.id))
        #expect(try world.journal.isOperatorAbortRequested(attemptID: second.id) == false)
        #expect(try abortRequestRows(world.journal) == 1)
        #expect(try world.journal.attempt(id: second.id)?.isOpen == true)
        #expect(output.lines == ["Aborting Attempt \(first.id) (A-1) in Project alpha: requested its abort."])
    }

    @Test("An ended Attempt: nothing is written")
    func endedAttemptWritesNothing() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try makeAbortWorld(try fixture.open(), feature: "A-F")
        let attempt = try world.attempt(try world.card("A-1"))
        _ = try world.journal.endAttempt(
            attemptID: attempt.id, ending: .hardFailure(.exitStatus(1)), runID: world.runID, act: .build
        )
        let output = RecordingOutput()

        try await abort(world.journal, attempt: attempt.id, output: output)

        #expect(try abortRequestRows(world.journal) == 0)
        #expect(output.lines == ["Attempt \(attempt.id) (A-1) already ended hard failure: nothing to abort."])
    }

    @Test("An unknown Attempt is an error naming it and the Project, and writes nothing")
    func unknownAttemptThrows() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try makeAbortWorld(try fixture.open(), feature: "A-F")
        _ = try world.attempt(try world.card("A-1"))
        let output = RecordingOutput()

        await #expect(throws: AttemptAbortError.self) {
            try await abort(world.journal, attempt: 9999, output: output)
        }

        let message = AttemptAbortError.unknownAttempt(
            attemptID: 9999, projectID: try #require(ProjectID(rawValue: "alpha"))
        ).localizedDescription
        #expect(message.contains("9999") && message.contains("alpha"))
        #expect(try abortRequestRows(world.journal) == 0)
        #expect(output.lines.isEmpty)
    }

    @Test("Aborting in one Project leaves every other Project untouched")
    func otherProjectsAreUntouched() async throws {
        let directory = ConfigurationDirectory()
        let alphaID = try #require(ProjectID(rawValue: "alpha"))
        let betaID = try #require(ProjectID(rawValue: "beta"))
        let alpha = try makeAbortWorld(
            try JournalStore.openSeeded(configurationDirectory: directory.url, projectID: alphaID), feature: "A-F"
        )
        let beta = try makeAbortWorld(
            try JournalStore.openSeeded(configurationDirectory: directory.url, projectID: betaID), feature: "B-F"
        )
        let alphaAttempt = try alpha.attempt(try alpha.card("A-1"))
        let betaAttempt = try beta.attempt(try beta.card("B-1"))
        let output = RecordingOutput()

        try await abort(alpha.journal, attempt: alphaAttempt.id, output: output)

        #expect(try alpha.journal.isOperatorAbortRequested(attemptID: alphaAttempt.id))
        #expect(try abortRequestRows(beta.journal) == 0)
        #expect(try beta.journal.attempt(id: betaAttempt.id)?.isOpen == true)
    }

    @Test("Waiting prints the ended line once the Act ends the Attempt aborted")
    func waitsForTheAttemptToEnd() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try makeAbortWorld(try fixture.open(), feature: "A-F")
        let attempt = try world.attempt(try world.card("A-1"))
        let output = RecordingOutput()
        let journal = world.journal
        let runID = world.runID

        async let ended: Void = {
            while !(try journal.isOperatorAbortRequested(attemptID: attempt.id)) {
                try await Task.sleep(for: .milliseconds(5))
            }
            _ = try journal.endAttempt(attemptID: attempt.id, ending: .aborted, runID: runID, act: .build)
        }()
        let started = ContinuousClock.now
        try await abort(journal, attempt: attempt.id, wait: .seconds(10), output: output)
        try await ended

        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(output.lines == [
            "Aborting Attempt \(attempt.id) (A-1) in Project alpha: requested its abort.",
            "Attempt \(attempt.id) (A-1) ended aborted."
        ])
    }

    @Test("The request is recorded before the first output line")
    func requestPrecedesOutput() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try makeAbortWorld(try fixture.open(), feature: "A-F")
        let attempt = try world.attempt(try world.card("A-1"))
        let journal = world.journal
        let seen = RecordingOutput()
        let attemptAbort = AttemptAbort(
            projectID: try #require(ProjectID(rawValue: "alpha")), attemptID: attempt.id,
            output: { _ in
                let recorded = (try? journal.isOperatorAbortRequested(attemptID: attempt.id)) == true
                seen.record(recorded ? "recorded" : "missing")
            },
            wait: .zero
        )

        try await attemptAbort.run(journal: journal)

        #expect(seen.lines == ["recorded"])
    }

    @Test("A Project with no Journal file: nothing to abort, and no Journal is created")
    func noJournalCreatesNothing() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "yellowhammer")
        let id = try #require(ProjectID(rawValue: "yellowhammer"))
        let parsed = try RootCommand.parseAsRoot(["abort", "--project", "yellowhammer", "--attempt", "1"])
        let command = try #require(parsed as? AbortCommand)

        try await command.run(configurationDirectory: directory.url)

        let file = JournalStore.defaultFileURL(configurationDirectory: directory.url, id: id)
        #expect(FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) == false)
    }
}
