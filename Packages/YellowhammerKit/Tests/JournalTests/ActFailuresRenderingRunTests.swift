import Domain
import Foundation
import Testing

@testable import Journal

private struct RenderingFixture: ~Copyable {
    let directory = FileManager.default.temporaryDirectory.appending(component: "yh-act-failures-\(UUID())")

    deinit { try? FileManager.default.removeItem(at: directory) }

    func open() throws -> JournalStore {
        try JournalStore.open(configurationDirectory: directory, projectID: #require(ProjectID(rawValue: "fixture")))
    }
}

private let renderingEpoch = Date(timeIntervalSince1970: 1_790_000_000)

@Suite("ActFailures: the rendering run's checkpoint")
struct ActFailuresRenderingRunTests {
    /// A land halt at `epoch`, then a later land run that has started and written one event but no `ActEnded`.
    private func seed(_ journal: JournalStore) throws -> (halted: RunID, rendering: RunID) {
        let halted = RunID()
        _ = try journal.claimActLease(act: .land, runID: halted, mode: .real, now: renderingEpoch)
        let nightStart = try #require(NightStart(rawValue: "2026-10-08"))
        let night = try journal.openNight(
            nightStart: nightStart, mode: .real, act: .land, runID: halted, now: renderingEpoch
        ).night
        try journal.append(.actStarted, act: .land, runID: halted, nightID: night.id, now: renderingEpoch)
        try journal.append(
            .actIncomplete(reason: "board unreachable"), act: .land, runID: halted, nightID: night.id,
            now: renderingEpoch.addingTimeInterval(1)
        )
        let rendering = RunID()
        let start = renderingEpoch.addingTimeInterval(3_600)
        try journal.append(.actStarted, act: .land, runID: rendering, nightID: night.id, now: start)
        try journal.append(
            .flushFiringRan(outcome: .closedNight, detail: nil), act: .land, runID: rendering, nightID: night.id,
            now: start.addingTimeInterval(5)
        )
        return (halted, rendering)
    }

    @Test("Without a rendering run, an unterminated later run of the Act recovers nothing")
    func unterminatedRunRecoversNothing() throws {
        let fixture = RenderingFixture()
        let journal = try fixture.open()
        _ = try seed(journal)

        let failures = ActFailures(events: try journal.events())
        let halted = try #require(failures.all.first)
        #expect(failures.recoveredAt(halted) == nil)
    }

    @Test("The rendering run's last recorded event recovers an earlier failure of its Act")
    func renderingRunRecoversAtItsLastEvent() throws {
        let fixture = RenderingFixture()
        let journal = try fixture.open()
        let runs = try seed(journal)

        let failures = ActFailures(events: try journal.events(), renderingRunID: runs.rendering)
        let halted = try #require(failures.all.first)
        #expect(failures.recoveredAt(halted) == renderingEpoch.addingTimeInterval(3_605))
    }

    @Test("A rendering run id that is not the later run changes nothing")
    func otherRenderingRunChangesNothing() throws {
        let fixture = RenderingFixture()
        let journal = try fixture.open()
        _ = try seed(journal)

        let failures = ActFailures(events: try journal.events(), renderingRunID: RunID())
        let halted = try #require(failures.all.first)
        #expect(failures.recoveredAt(halted) == nil)
    }

    @Test("A failure that came back later is recovered by the run between them only when asked per failure")
    func recoveryIgnoringLaterFailures() throws {
        let fixture = RenderingFixture()
        let journal = try fixture.open()
        let first = RunID()
        _ = try journal.claimActLease(act: .land, runID: first, mode: .real, now: renderingEpoch)
        let nightStart = try #require(NightStart(rawValue: "2026-10-08"))
        let night = try journal.openNight(
            nightStart: nightStart, mode: .real, act: .land, runID: first, now: renderingEpoch
        ).night
        func append(_ event: JournalEvent, _ run: RunID, at seconds: TimeInterval) throws {
            try journal.append(
                event, act: .land, runID: run, nightID: night.id, now: renderingEpoch.addingTimeInterval(seconds)
            )
        }
        try append(.actIncomplete(reason: "board unreachable"), first, at: 1)
        let recovering = RunID()
        try append(.actEnded, recovering, at: 600)
        try append(.actIncomplete(reason: "board unreachable"), RunID(), at: 1_200)

        let failures = ActFailures(events: try journal.events())
        let earliest = try #require(failures.all.first)
        #expect(failures.recoveredAt(earliest) == nil)
        #expect(
            failures.recoveredAt(earliest, ignoringLaterFailures: true)
                == renderingEpoch.addingTimeInterval(600)
        )
    }
}
