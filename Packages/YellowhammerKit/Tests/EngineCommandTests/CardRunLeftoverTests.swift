import Domain
@testable import Engine
import Foundation
import Journal
import Repositories
import Synchronization
import Testing

// Normal-Exit Sweep Ruling (issue #175): a swept or fenced leftover process does not change the
// Attempt's outcome (item 4), and an attributed process still holding the Worktree after the fence's
// quiescence timeout faults the run before the Check or the next pass ever starts.

/// A Dispatch seam that answers every pass from ``RehearsalDispatch``, then overrides one named
/// pass's report with `leftovers`/`snapshot`/`origin`, so a Card run sees a normal-exit report to
/// sweep without a real agent CLI process.
private struct LeftoverDispatch: AgentDispatch {
    let log: CallLog
    let pass: RunPass
    let leftovers: [LeftoverProcess]
    let snapshot: RunningSnapshot?

    func dispatch(_ request: AgentDispatchRequest) async throws -> AgentDispatchReport {
        log.add("dispatch \(request.pass.rawValue)")
        let report = try await RehearsalDispatch().dispatch(request)
        guard request.pass == pass else { return report }
        return AgentDispatchReport(
            outcome: report.outcome, session: report.session, origin: .agentCLIProcess, leftovers: leftovers,
            snapshot: snapshot
        )
    }
}

/// A fake ``NormalExitFencing`` that logs every call it saw and answers from a scripted outcome.
private final class RecordingNormalExitFencing: NormalExitFencing, Sendable {
    private let log: CallLog?
    private let outcome: AttributedFencingOutcome
    private let calls = Mutex<Int>(0)

    init(log: CallLog? = nil, outcome: AttributedFencingOutcome) {
        self.log = log
        self.outcome = outcome
    }

    var callCount: Int { calls.withLock { $0 } }

    func fence(worktreePath: String, attributedTo snapshot: RunningSnapshot) async -> AttributedFencingOutcome {
        log?.add("fence")
        calls.withLock { $0 += 1 }
        return outcome
    }
}

private func leftoverSnapshot() -> RunningSnapshot {
    RunningSnapshot(
        dispatchedAt: ProcessStartTime(seconds: 0, microseconds: 0),
        processes: [
            SnapshotProcess(
                pid: 4242, startTime: ProcessStartTime(seconds: 1, microseconds: 0), processGroup: 4242,
                session: 4242, commandName: "node"
            )
        ],
        processGroups: [4242], sessions: []
    )
}

@Suite("Card run leftover accounting (Normal-Exit Sweep Ruling, issue #175)")
struct CardRunLeftoverTests {
    @Test("A swept and fenced leftover on the worker pass does not change the Attempt's outcome")
    func sweptLeftoverDoesNotChangeAttemptOutcome() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())
        let log = CallLog()
        let leftover = LeftoverProcess(pid: 4242, commandName: "node", processGroup: 4242, session: 4242)
        let fencing = RecordingNormalExitFencing(
            log: log,
            outcome: .quiescent(
                killed: [FencedProcess(pid: 4343, commandName: "python3")],
                unattributed: [UnattributedProcess(pid: 4444, commandName: "sleep", cwd: "/tmp/yh-wt-backend")]
            )
        )
        let run = CardRun(
            resolver: cardRunResolver(),
            dispatch: LeftoverDispatch(log: log, pass: .worker, leftovers: [leftover], snapshot: leftoverSnapshot()),
            check: RecordingCheck(log: log), checks: ["backend": .none], reviewRoundsMax: 2, attemptsPerCard: 3,
            resetting: RecordingAttemptResetting(), normalExitFencing: fencing
        )

        try await run.run("BACK-1", in: world)

        // Same happy-path outcome as CardRunTests' baseline: the leftover accounting never touches it.
        #expect(try cardRunLog(world.journal) == [
            "lease-claimed", "attempt-started", "→ In Progress", "architect", "worker", "check", "reviewer",
            "attempt ended: success", "→ Done", "lease-released"
        ])
        let attempt = try #require(try world.attempts("BACK-1").first)
        #expect(attempt.result == "success")
        #expect(try world.card("BACK-1").state == .done)
        #expect(fencing.callCount == 1)

        let events = try world.journal.events(ofType: .leftoverProcessRecorded)
        #expect(events.count == 3)
        for record in events {
            guard case .leftoverProcessRecorded(_, let issueID, let attemptID, let pass, _, _, _, _) = record.event
            else {
                Issue.record("expected leftoverProcessRecorded")
                continue
            }
            #expect(issueID == "BACK-1")
            #expect(attemptID == attempt.id)
            #expect(pass == .worker)
        }
        let dispositions = events.compactMap { record -> LeftoverProcessDisposition? in
            if case .leftoverProcessRecorded(_, _, _, _, _, _, let disposition, _) = record.event {
                disposition
            } else {
                nil
            }
        }
        #expect(Set(dispositions) == Set(LeftoverProcessDisposition.allCases))
    }

    @Test("A .notQuiescent fence faults the run: no Check runs, and what was killed/unattributed is recorded first")
    func notQuiescentFaultsTheRun() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())
        let log = CallLog()
        let fencing = RecordingNormalExitFencing(
            log: log,
            outcome: .notQuiescent(
                killed: [], remaining: [FencedProcess(pid: 4343, commandName: "python3")], unattributed: []
            )
        )
        let run = CardRun(
            resolver: cardRunResolver(),
            dispatch: LeftoverDispatch(log: log, pass: .worker, leftovers: [], snapshot: leftoverSnapshot()),
            check: RecordingCheck(log: log), checks: ["backend": .none], reviewRoundsMax: 2, attemptsPerCard: 3,
            resetting: RecordingAttemptResetting(), normalExitFencing: fencing
        )

        await #expect(throws: CardRunError.self) {
            try await run.run("BACK-1", in: world)
        }

        #expect(!log.all.contains("check"))
        let steps = try cardRunLog(world.journal)
        #expect(!steps.contains(CardRunStep.check.rawValue))
        #expect(try world.journal.events(ofType: .checkRan).isEmpty)
    }

    @Test("A report with no running snapshot never calls the fence")
    func noSnapshotNeverCallsFence() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())
        let log = CallLog()
        let fencing = RecordingNormalExitFencing(log: log, outcome: .quiescent(killed: [], unattributed: []))

        try await CardRun(
            resolver: cardRunResolver(), dispatch: LoggingDispatch(log: log),
            check: RecordingCheck(log: log), checks: ["backend": .none], reviewRoundsMax: 2, attemptsPerCard: 3,
            resetting: RecordingAttemptResetting(), normalExitFencing: fencing
        ).run("BACK-1", in: world)

        #expect(fencing.callCount == 0)
        #expect(try world.journal.events(ofType: .leftoverProcessRecorded).isEmpty)
    }
}
