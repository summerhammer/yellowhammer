import Domain
@testable import EngineCommand
import Foundation
@testable import Journal
import Testing

// `yh stop` (P18.10): the request is recorded for one Project's running Attempts only, before any output.

private let stopRoute = Route(cli: "claude", model: "opus", effort: "high")!

private struct StopWorld {
    let journal: JournalStore
    let runID: RunID
    let cycleID: Int64

    func card(_ issueID: String) throws -> Int64 {
        try insertReconcilerCard(journal, cycleID: cycleID, issueID: issueID, repository: "backend", state: .inProgress)
    }

    func attempt(_ cardID: Int64) throws -> AttemptRecord {
        try journal.recordAttempt(cardID: cardID, route: stopRoute, runID: runID)
    }
}

private func makeStopWorld(_ journal: JournalStore, feature: String) throws -> StopWorld {
    let runID = RunID()
    _ = try journal.claimActLease(act: .build, runID: runID, mode: .rehearsal)
    let featureID = try insertReconcilerFeature(journal, issueID: feature)
    let cycleID = try insertReconcilerCycle(journal, featureID: featureID)
    return StopWorld(journal: journal, runID: runID, cycleID: cycleID)
}

private func requestRows(_ journal: JournalStore) throws -> Int {
    try journal.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM operator_abort_request") ?? 0 }
}

private func stop(
    _ journal: JournalStore, project: String = "alpha", wait: Duration = .zero, output: RecordingOutput
) async throws {
    let engineStop = EngineStop(
        projectID: try #require(ProjectID(rawValue: project)), output: { output.record($0) },
        poll: .milliseconds(20), wait: wait
    )
    try await engineStop.run(journal: journal)
}

@Suite("yh stop: EngineStop")
struct EngineStopTests {
    @Test("Stopping one Project leaves every other Project untouched")
    func otherProjectsAreUntouched() async throws {
        let directory = ConfigurationDirectory()
        let alphaID = try #require(ProjectID(rawValue: "alpha"))
        let betaID = try #require(ProjectID(rawValue: "beta"))
        let alpha = try makeStopWorld(
            try JournalStore.openSeeded(configurationDirectory: directory.url, projectID: alphaID), feature: "A-F"
        )
        let beta = try makeStopWorld(
            try JournalStore.openSeeded(configurationDirectory: directory.url, projectID: betaID), feature: "B-F"
        )
        let alphaAttempt = try alpha.attempt(try alpha.card("A-1"))
        let betaAttempt = try beta.attempt(try beta.card("B-1"))
        let output = RecordingOutput()

        try await stop(alpha.journal, output: output)

        #expect(try alpha.journal.isOperatorAbortRequested(attemptID: alphaAttempt.id))
        #expect(try requestRows(beta.journal) == 0)
        #expect(try beta.journal.attempt(id: betaAttempt.id)?.isOpen == true)
        #expect(output.lines == [
            "Stopping the engine for Project alpha: requested an abort of 1 running Attempt(s): \(alphaAttempt.id)."
        ])
    }

    @Test("No running Attempt: nothing to stop, and no rows")
    func nothingToStop() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try makeStopWorld(try fixture.open(), feature: "A-F")
        _ = try world.card("A-1")
        let output = RecordingOutput()

        try await stop(world.journal, output: output)

        #expect(output.lines == ["No Attempt is running in Project alpha: nothing to stop."])
        #expect(try requestRows(world.journal) == 0)
    }

    @Test("Waiting prints the ended line once the Act ends the Attempt aborted")
    func waitsForTheAttemptToEnd() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try makeStopWorld(try fixture.open(), feature: "A-F")
        let cardID = try world.card("A-1")
        let attempt = try world.attempt(cardID)
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
        try await stop(journal, wait: .seconds(60), output: output)
        try await ended

        #expect(ContinuousClock.now - started < .seconds(30))
        #expect(output.lines.last == "Attempt \(attempt.id) (A-1) ended aborted.")
    }

    @Test("A retry of the same Card is requested too; another Card's new Attempt is not")
    func retryRaceRequestsTheNewAttempt() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try makeStopWorld(try fixture.open(), feature: "A-F")
        let cardID = try world.card("A-1")
        let otherCard = try world.card("A-2")
        let first = try world.attempt(cardID)
        let output = RecordingOutput()
        let journal = world.journal
        let runID = world.runID

        async let retried: (Int64, Int64) = {
            while !(try journal.isOperatorAbortRequested(attemptID: first.id)) {
                try await Task.sleep(for: .milliseconds(5))
            }
            _ = try journal.endAttempt(
                attemptID: first.id, ending: .hardFailure(.exitStatus(1)), runID: runID, act: .build
            )
            // The Worktree reset between Attempts: several polls pass with the Card In Progress and no
            // open Attempt.
            try await Task.sleep(for: .milliseconds(150))
            let retry = try journal.recordAttempt(cardID: cardID, route: stopRoute, runID: runID)
            let unrelated = try journal.recordAttempt(cardID: otherCard, route: stopRoute, runID: runID)
            while !(try journal.isOperatorAbortRequested(attemptID: retry.id)) {
                try await Task.sleep(for: .milliseconds(5))
            }
            _ = try journal.endAttempt(attemptID: retry.id, ending: .aborted, runID: runID, act: .build)
            return (retry.id, unrelated.id)
        }()
        try await stop(journal, wait: .seconds(60), output: output)
        let (retryID, unrelatedID) = try await retried

        #expect(output.lines.contains("Attempt \(retryID) (A-1) started after the stop: requested its abort too."))
        #expect(output.lines.contains("Attempt \(first.id) (A-1) ended hard failure."))
        #expect(try journal.isOperatorAbortRequested(attemptID: unrelatedID) == false)
    }

    @Test("A Card that leaves In Progress after its Attempt ended on its own is no longer watched")
    func cardLeavingInProgressEndsTheWatch() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try makeStopWorld(try fixture.open(), feature: "A-F")
        let cardID = try world.card("A-1")
        let attempt = try world.attempt(cardID)
        let output = RecordingOutput()
        let journal = world.journal
        let runID = world.runID

        async let ended: Void = {
            while !(try journal.isOperatorAbortRequested(attemptID: attempt.id)) {
                try await Task.sleep(for: .milliseconds(5))
            }
            _ = try journal.endAttempt(
                attemptID: attempt.id, ending: .hardFailure(.exitStatus(1)), runID: runID, act: .build
            )
            _ = try journal.transitionCard(
                cardID: cardID, to: .blocked, blockReason: .routeFailure, runID: runID, act: .build, nightID: nil
            )
        }()
        let started = ContinuousClock.now
        try await stop(journal, wait: .seconds(60), output: output)
        try await ended

        #expect(ContinuousClock.now - started < .seconds(30))
        #expect(output.lines.last == "Attempt \(attempt.id) (A-1) ended hard failure.")
    }

    @Test("A deadline passing leaves the request recorded and says the Attempt is still running")
    func deadlineReportsStillRunning() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try makeStopWorld(try fixture.open(), feature: "A-F")
        let attempt = try world.attempt(try world.card("A-1"))
        let output = RecordingOutput()

        try await stop(world.journal, wait: .milliseconds(60), output: output)

        #expect(try world.journal.isOperatorAbortRequested(attemptID: attempt.id))
        #expect(output.lines.last?.hasPrefix("Attempt \(attempt.id) (A-1) is still running; its abort request") == true)
    }

    @Test("The request is recorded before the first output line")
    func requestPrecedesOutput() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try makeStopWorld(try fixture.open(), feature: "A-F")
        let attempt = try world.attempt(try world.card("A-1"))
        let journal = world.journal
        let seenRecorded = RecordingOutput()
        let engineStop = EngineStop(
            projectID: try #require(ProjectID(rawValue: "alpha")),
            output: { line in
                if line.hasPrefix("Stopping the engine") {
                    let recorded = (try? journal.isOperatorAbortRequested(attemptID: attempt.id)) == true
                    seenRecorded.record(recorded ? "recorded" : "missing")
                }
            },
            wait: .zero
        )

        try await engineStop.run(journal: journal)

        #expect(seenRecorded.lines == ["recorded"])
    }
}
