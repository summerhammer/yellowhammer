import Domain
@testable import Engine
import Foundation
@testable import Journal
import Testing

// loop-state/claim-and-heartbeat-a-run-lease, as the Card run keeps it (roadmap P8.4): a Card another
// run holds is never dispatched; the Lease is heartbeated for as long as a pass runs; a Lease lost
// mid-run stops the run, and nothing is written as if it were complete.

@Suite("Card run Lease")
struct CardRunLeaseTests {
    private func makeRun(
        log: CallLog, leasePolicy: LeasePolicy = .ruled, during: (@Sendable (RunPass) async throws -> Void)? = nil
    ) -> CardRun {
        CardRun(
            resolver: cardRunResolver(), dispatch: LoggingDispatch(log: log, during: during),
            check: RecordingCheck(log: log), checks: ["backend": .none], reviewRoundsMax: 2, attemptsPerCard: 3,
            leasePolicy: leasePolicy,
            resetting: RecordingAttemptResetting()
        )
    }

    @Test("A Card another run holds under an unexpired Lease is skipped: no Attempt, nothing dispatched")
    func heldCardIsSkipped() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())
        let cardID = try #require(world.cardIDs["BACK-1"])
        let other = RunID()
        _ = try world.journal.claimCardLease(cardID: cardID, runID: other)
        let log = CallLog()

        try await makeRun(log: log).run("BACK-1", in: world)

        #expect(log.all.isEmpty)
        #expect(try world.attempts("BACK-1").isEmpty)
        #expect(try world.card("BACK-1").state == .todo)
        #expect(try world.journal.currentCardLease(cardID: cardID)?.runID == other)
        #expect(try cardRunLog(world.journal) == ["skipped-lease-held"])
    }

    @Test("The Lease is heartbeated while a pass runs: still held at its original expiry only because of a beat")
    func leaseIsHeartbeatedWhileAPassRuns() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())
        let cardID = try #require(world.cardIDs["BACK-1"])
        let policy = LeasePolicy(heartbeatInterval: 0.05, timeToLive: 30)
        let journal = world.journal
        let runID = world.runID
        let log = CallLog()

        let run = makeRun(log: log, leasePolicy: policy) { pass in
            guard pass == .worker else { return }
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while ContinuousClock.now < deadline {
                let lease = try #require(try journal.currentCardLease(cardID: cardID))
                if lease.heartbeatAt > lease.claimedAt {
                    let originalExpiry = lease.claimedAt.addingTimeInterval(policy.timeToLive)
                    #expect(lease.expiresAt > originalExpiry)
                    // At the original expiry the Lease is held only because a beat extended it.
                    _ = try journal.revalidateCardLease(cardID: cardID, runID: runID, now: originalExpiry)
                    log.add("lease held at original expiry")
                    return
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            Issue.record("The Card run did not heartbeat while the worker pass was running")
        }
        try await run.run("BACK-1", in: world)

        #expect(log.all.contains("lease held at original expiry"))
        #expect(try world.card("BACK-1").state == .done)
    }

    @Test("A Lease lost mid-run stops the run: the Card is reclaimable, no partial state written as if complete")
    func lostLeaseStopsTheRun() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())
        let cardID = try #require(world.cardIDs["BACK-1"])
        let policy = LeasePolicy(heartbeatInterval: 0.05, timeToLive: 600)
        let journal = world.journal
        let runID = world.runID
        let other = RunID()
        let log = CallLog()

        let run = makeRun(log: log, leasePolicy: policy) { pass in
            guard pass == .worker else { return }
            // Another run takes the Card over while the worker is still running.
            try journal.releaseCardLease(cardID: cardID, runID: runID)
            _ = try journal.claimCardLease(cardID: cardID, runID: other)
            try await Task.sleep(for: .seconds(5))
        }
        try await run.run("BACK-1", in: world)

        // The reviewer never ran, and nothing says the Card completed.
        #expect(log.all == ["dispatch architect", "dispatch worker"])
        let attempt = try #require(try world.attempts("BACK-1").first)
        #expect(attempt.isOpen)
        #expect(attempt.result == nil)
        #expect(try world.card("BACK-1").state == .inProgress)
        let story = try cardRunLog(world.journal)
        #expect(story.contains("lease-lost"))
        #expect(!story.contains("attempt ended: success"))
        #expect(!story.contains("→ Done"))
        #expect(!story.contains("lease-released"))
        // The Lease is the other run's: this run released nothing of it.
        #expect(try world.journal.currentCardLease(cardID: cardID)?.runID == other)
    }
}
