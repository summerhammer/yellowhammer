import Domain
@testable import Engine
import Foundation
import GRDB
import Synchronization
import Testing

@testable import Journal

// P15.3: a rehearsal-only kill switch for `Outbox` replay. The spec string names which applied entry to
// kill after; the switch itself counts entries and fires the (injectable) kill action exactly once, only
// after the board has applied the write and before the Journal records it.

private let noopKill: @Sendable () -> Void = {}

@Suite("RehearsalOutboxKill: spec parsing")
struct RehearsalOutboxKillParsingTests {
    @Test("A bare positive integer parses as an any-scope switch", arguments: ["1", "2", "42"])
    func bareIntegerParses(_ raw: String) {
        let parsed = RehearsalOutboxKill(spec: raw, kill: noopKill)
        #expect(parsed != nil)
    }

    @Test("group:<n> parses as a group-scope switch", arguments: ["group:1", "group:9"])
    func groupPrefixedIntegerParses(_ raw: String) {
        let parsed = RehearsalOutboxKill(spec: raw, kill: noopKill)
        #expect(parsed != nil)
    }

    @Test(
        "Zero, negative, non-numeric, and malformed group specs are refused",
        arguments: ["0", "-1", "abc", "group:", "group:0", "group:-1", "group:abc", "", "1.5", " 1"]
    )
    func malformedSpecsAreRefused(_ raw: String) {
        let parsed = RehearsalOutboxKill(spec: raw, kill: noopKill)
        #expect(parsed == nil)
    }
}

@Suite("RehearsalOutboxKill: fires on the n-th matching entry, after the board applied it")
struct RehearsalOutboxKillFiringTests {
    @Test("An any-scope switch fires on the n-th entry of any kind")
    func anyScopeFiresOnNthEntry() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let board = FakeWritingBoard()
        let fired = Mutex(0)
        let recordFired: @Sendable () -> Void = { fired.withLock { $0 += 1 } }
        let maybeSwitch = RehearsalOutboxKill(spec: "2", kill: recordFired)
        let killSwitch = try #require(maybeSwitch)
        let rig = try outbox(journal, board: board, interrupt: { killSwitch.interrupt($0) })

        _ = try await rig.post(OutboxWrite(key: "a", write: card("Card A")))
        #expect(fired.withLock { $0 } == 0)
        _ = try await rig.post(OutboxWrite(key: "b", write: card("Card B")))

        #expect(fired.withLock { $0 } == 1)
    }

    @Test("A group-scope switch counts only grouped entries, skipping ungrouped ones")
    func groupScopeCountsOnlyGroupedEntries() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let board = FakeWritingBoard()
        let fired = Mutex(0)
        let recordFired: @Sendable () -> Void = { fired.withLock { $0 += 1 } }
        let maybeSwitch = RehearsalOutboxKill(spec: "group:2", kill: recordFired)
        let killSwitch = try #require(maybeSwitch)
        let rig = try outbox(journal, board: board, interrupt: { killSwitch.interrupt($0) })

        // Ungrouped entry: not counted by a group-scope switch.
        _ = try await rig.post(OutboxWrite(key: "ungrouped", write: card("Ungrouped")))
        #expect(fired.withLock { $0 } == 0)

        // First grouped entry: counted (1 of 2).
        _ = try rig.acceptGroup(
            [OutboxWrite(key: "group:1:create", write: card("Group One"))], key: "group:1"
        )
        _ = try await rig.deliverPending()
        #expect(fired.withLock { $0 } == 0)

        // Second grouped entry: counted (2 of 2) — fires.
        _ = try rig.acceptGroup(
            [OutboxWrite(key: "group:2:create", write: card("Group Two"))], key: "group:2"
        )
        _ = try await rig.deliverPending()

        #expect(fired.withLock { $0 } == 1)
    }

    @Test("The interrupt hook fires after the board applied the write, before the Journal recorded it")
    func firesOnlyAfterTheBoardAppliedTheWrite() async throws {
        // Same idiom as OutboxGroupTests' groupCompletesOnReplay: a throw from the interrupt hook halts
        // Outbox processing at exactly the point `RehearsalOutboxKill.interrupt` itself would fire, so the
        // state visible right after the throw is the state visible at the instant a real kill would land.
        struct HaltAtInterrupt: Error {}
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let board = FakeWritingBoard()
        let maybeSwitch = RehearsalOutboxKill(spec: "1", kill: noopKill)
        let killSwitch = try #require(maybeSwitch)
        let rig = try outbox(journal, board: board, interrupt: { entry in
            killSwitch.interrupt(entry)
            throw HaltAtInterrupt()
        })

        await #expect(throws: HaltAtInterrupt.self) {
            try await rig.post(OutboxWrite(key: "a", write: card("Card A")))
        }

        #expect(await board.liveIssues.map(\.title) == ["Card A"])
        #expect(try journal.pendingOutboxEntries().count == 1)
    }

    @Test("Never fires twice: a third entry past the target does not call kill again")
    func neverFiresTwice() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let board = FakeWritingBoard()
        let fired = Mutex(0)
        let recordFired: @Sendable () -> Void = { fired.withLock { $0 += 1 } }
        let maybeSwitch = RehearsalOutboxKill(spec: "1", kill: recordFired)
        let killSwitch = try #require(maybeSwitch)
        let rig = try outbox(journal, board: board, interrupt: { killSwitch.interrupt($0) })

        _ = try await rig.post(OutboxWrite(key: "a", write: card("Card A")))
        _ = try await rig.post(OutboxWrite(key: "b", write: card("Card B")))
        _ = try await rig.post(OutboxWrite(key: "c", write: card("Card C")))

        #expect(fired.withLock { $0 } == 1)
    }
}
