import Domain
import Foundation
import Testing

@testable import Journal
@testable import Pulse

// A failed item carries which Act's log the app can point to, and only a failed item does
// (morning-report/disclose-a-failure#log-path). Pulse carries the Act, never a path: the app composes the URL.

private struct LogFixture: ~Copyable {
    let directory = FileManager.default.temporaryDirectory.appending(component: "yh-pulse-log-\(UUID())")

    deinit { try? FileManager.default.removeItem(at: directory) }

    func open() throws -> JournalStore {
        try JournalStore.open(configurationDirectory: directory, projectID: #require(ProjectID(rawValue: "fixture")))
    }
}

private func record(_ event: JournalEvent, act: Act? = .land) -> JournalEventRecord {
    JournalEventRecord(
        id: 7, event: event, act: act, runID: nil, nightID: 1, occurredAt: Date(timeIntervalSince1970: 0)
    )
}

@Suite("The Act whose log a failed item points to")
struct FailedActLogTests {
    @Test("An Act failure's Health row and Failure Notice carry the Act that failed")
    func failureCarriesItsAct() throws {
        let fixture = LogFixture()
        let journal = try fixture.open()
        let run = RunID()
        _ = try journal.claimActLease(act: .build, runID: run, mode: .real, now: epoch)
        let opening = try journal.openNight(nightStart: nightStart, mode: .real, act: .build, runID: run, now: epoch)
        try journal.append(
            .actIncomplete(reason: "Linear returned 503"), act: .build, runID: run, nightID: opening.night.id,
            now: epoch
        )

        let failures = JournalFailures(events: try journal.events())
        #expect(failures.flags.first?.kind == .actFailure)
        #expect(failures.flags.first?.failedAct == .build)
        #expect(failures.notices.first?.failedAct == .build)
    }

    @Test("A flag that is no Act failure offers no log")
    func otherFlagsCarryNoAct() {
        #expect(HealthFlag(kind: .undeliveredBoardWrites, detail: "2 writes").failedAct == nil)
        #expect(HealthFlag(kind: .probeFailure, detail: "claude").failedAct == nil)
    }

    @Test("A problem entry carries its Act; a running or successful entry does not")
    func entriesCarryAnActOnlyWhenFailed() {
        let failed = NightAccount.Entry(
            record: record(.actIncomplete(reason: "Linear returned 503")), cardNames: [:]
        )
        #expect(failed.isProblem)
        #expect(failed.failedAct == .land)
        let started = NightAccount.Entry(record: record(.actStarted), cardNames: [:])
        let ended = NightAccount.Entry(record: record(.actEnded), cardNames: [:])
        #expect(started.failedAct == nil)
        #expect(ended.failedAct == nil)
    }

    @Test("A problem entry that records no Act carries none")
    func problemWithoutAnAct() {
        let entry = NightAccount.Entry(
            record: record(.actIncomplete(reason: "x"), act: nil), cardNames: [:]
        )
        #expect(entry.isProblem)
        #expect(entry.failedAct == nil)
    }
}
