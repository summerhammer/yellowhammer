import ArgumentParser
import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
import Journal
import Synchronization
import Testing

// roadmap P17.5, Linear Board Connection Ruling items 5, 12, 13: an authorization failure
// (BoardError.notAuthenticated) halts the Act before any board work — the preflight identity() read
// is the Act's first Linear call — records `.linearAuthorizationHalted` alongside `.actIncomplete`,
// and posts the local halted notification once per Night. A network error (.unreachable) is not this
// cause and keeps today's behaviour.

private struct SampleWorkFailure: Error, CustomStringConvertible, Equatable {
    let description: String
}

/// Records every notification a fake `ExceptionNotifier` was asked to post.
private final class NotificationRecorder: Sendable {
    private let storage = Mutex<[ExceptionNotification]>([])

    func record(_ notification: ExceptionNotification) {
        storage.withLock { $0.append(notification) }
    }

    var notifications: [ExceptionNotification] { storage.withLock { $0 } }
}

@Suite("Linear authorization halt (P17.5)")
struct LinearAuthorizationHaltTests {
    private static let authorizationCopy =
        "Linear refused Yellowhammer's sign-in. Re-connect the Linear workspace: " +
            "the Linear step of yh setup, or Settings → Board connections in Yellowhammer.app."
    private static let labelledCopy =
        "Linear refused Yellowhammer's sign-in for the Linear workspace \"acme\". " +
            "Re-connect that workspace: the Linear step of yh setup, or Settings → Board connections " +
            "in Yellowhammer.app."

    @Test("A labelled board's authorization halt names the workspace and both fixes")
    func labelledHaltNamesTheWorkspace() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let reading = FakeReadingBoard([])
        await reading.script(identity: .failure(.notAuthenticated("sign-in expired")))
        let board = ActBoard(
            reading: reading, writing: boards.writing, provisioning: boards.provisioning,
            installation: AppInstallationLabel(name: "acme", workspace: BoardObjectID(rawValue: "workspace-1"))
        )
        let recorder = NotificationRecorder()
        let invocation = EngineInvocation(
            act: .build, mode: .real, nightStart: nightCardNightStart, journal: journal,
            trigger: .forced, runID: RunID(), board: board,
            notifier: ExceptionNotifier { recorder.record($0) },
            work: { _ in }
        )

        await #expect(throws: (any Error).self) { try await invocation.run() }

        let notification = try #require(recorder.notifications.first)
        guard case .halted(let reason) = notification.event else {
            Issue.record("expected .halted, got \(notification.event)")
            return
        }
        #expect(reason == Self.labelledCopy)
        #expect(reason.contains("\"acme\""))
        #expect(reason.contains("the Linear step of yh setup"))
        #expect(reason.contains("Settings → Board connections in Yellowhammer.app"))
    }

    @Test("A refused identity halts before the Night Card, before work, records the cause once, and posts once")
    func preflightRefusalHaltsBeforeNightCardAndWork() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let reading = FakeReadingBoard([])
        await reading.script(identity: .failure(.notAuthenticated("sign-in expired")))
        let board = ActBoard(reading: reading, writing: boards.writing, provisioning: boards.provisioning)
        let recorder = NotificationRecorder()
        let workRan = Mutex(false)

        let invocation = EngineInvocation(
            act: .build, mode: .real, nightStart: nightCardNightStart, journal: journal,
            trigger: .forced, runID: RunID(), board: board,
            notifier: ExceptionNotifier { recorder.record($0) },
            work: { _ in workRan.withLock { $0 = true } }
        )

        do {
            try await invocation.run()
            Issue.record("expected the authorization failure to be rethrown")
        } catch let error as BoardError {
            guard case .notAuthenticated = error else {
                Issue.record("expected notAuthenticated, got \(error)")
                return
            }
        } catch {
            Issue.record("wrong error type: \(error)")
        }

        #expect(!workRan.withLock { $0 })
        #expect(await boards.writing.createIssueCalls == 0, "no Night Card create was attempted")
        let events = try journal.events().map(\.type)
        #expect(events.contains(.actIncomplete))
        #expect(events.contains(.linearAuthorizationHalted))
        #expect(!events.contains(.nightCardOpened))

        #expect(recorder.notifications.count == 1)
        let notification = try #require(recorder.notifications.first)
        guard case .halted(let reason) = notification.event else {
            Issue.record("expected .halted, got \(notification.event)")
            return
        }
        #expect(reason == Self.authorizationCopy)
    }

    @Test("A second Act's authorization halt in the same Night records only; a later different-cause halt still posts")
    func secondAuthHaltInSameNightRecordsOnlyLaterDifferentCauseStillPosts() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let recorder = NotificationRecorder()

        func haltingInvocation(act: Act) async -> EngineInvocation {
            let reading = FakeReadingBoard([])
            await reading.script(identity: .failure(.notAuthenticated("sign-in expired")))
            let board = ActBoard(reading: reading, writing: boards.writing, provisioning: boards.provisioning)
            return EngineInvocation(
                act: act, mode: .real, nightStart: nightCardNightStart, journal: journal,
                trigger: .forced, runID: RunID(), board: board,
                notifier: ExceptionNotifier { recorder.record($0) },
                work: { _ in }
            )
        }

        // First Act of the Night: authorization halt, posts once.
        await #expect(throws: (any Error).self) { try await (await haltingInvocation(act: .author)).run() }
        #expect(recorder.notifications.count == 1)

        // Second Act, same Night, also an authorization halt: recorded, no second post.
        await #expect(throws: (any Error).self) { try await (await haltingInvocation(act: .build)).run() }
        #expect(recorder.notifications.count == 1)

        let authHalts = try journal.events(ofType: .linearAuthorizationHalted)
        #expect(authHalts.count == 2)

        // A third Act, same Night, halted for a different cause entirely: still posts.
        let readingHealthy = FakeReadingBoard([])
        let boardHealthy = ActBoard(
            reading: readingHealthy, writing: boards.writing, provisioning: boards.provisioning
        )
        let failure = SampleWorkFailure(description: "boom")
        let thirdInvocation = EngineInvocation(
            act: .land, mode: .real, nightStart: nightCardNightStart, journal: journal,
            trigger: .forced, runID: RunID(), board: boardHealthy,
            notifier: ExceptionNotifier { recorder.record($0) },
            work: { _ in throw failure }
        )
        do {
            try await thirdInvocation.run()
            Issue.record("expected the work error to be rethrown")
        } catch let error as SampleWorkFailure {
            #expect(error == failure)
        } catch {
            Issue.record("wrong error type: \(error)")
        }

        #expect(recorder.notifications.count == 2)
        guard case .halted(let reason) = recorder.notifications[1].event else {
            Issue.record("expected .halted, got \(recorder.notifications[1].event)")
            return
        }
        #expect(reason.contains("boom"))
        #expect(reason != Self.authorizationCopy)
    }

    @Test("A Night whose Acts all halted on authorization has no dispatched work and no advanced clock")
    func nightWithOnlyAuthorizationHaltsAdvancesNoClock() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()

        for act: Act in [.author, .build, .land] {
            let reading = FakeReadingBoard([])
            await reading.script(identity: .failure(.notAuthenticated("sign-in expired")))
            let board = ActBoard(reading: reading, writing: boards.writing, provisioning: boards.provisioning)
            let invocation = EngineInvocation(
                act: act, mode: .real, nightStart: nightCardNightStart, journal: journal,
                trigger: .forced, runID: RunID(), board: board, work: { _ in Issue.record("work must not run") }
            )
            await #expect(throws: (any Error).self) { try await invocation.run() }
        }

        // Nothing that could advance a clock ever ran: no dispatch, no Card or Feature event of any kind.
        let types = Set(try journal.events().map(\.type))
        let clockAdvancingTypes: Set<JournalEventType> = [
            .cardUnansweredBoundFired, .refusalExpired, .authoringHaltExpired, .attemptEnded,
            .featureSelected, .featureAuthored, .cardStateTransitioned
        ]
        #expect(types.isDisjoint(with: clockAdvancingTypes))
        #expect(await boards.writing.createIssueCalls == 0)
    }

    @Test("A mid-Act write refused as notAuthenticated halts the Act, and the write stays pending")
    func midActWriteRefusalHaltsAndStaysPending() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)

        // The Night Card create itself is the write refused: the first Outbox write of any Act.
        await boards.writing.refuseNext(.notAuthenticated("sign-in expired"))

        let invocation = EngineInvocation(
            act: .build, mode: .real, nightStart: nightCardNightStart, journal: journal,
            trigger: .forced, runID: RunID(), board: board, work: { _ in Issue.record("work must not run") }
        )

        do {
            try await invocation.run()
            Issue.record("expected the authorization failure to be rethrown")
        } catch let error as BoardError {
            guard case .notAuthenticated = error else {
                Issue.record("expected notAuthenticated, got \(error)")
                return
            }
        } catch {
            Issue.record("wrong error type: \(error)")
        }

        // The entry stays pending: not counted as an attempt, not failed.
        let pending = try journal.pendingOutboxEntries()
        #expect(pending.count == 1)

        // A later, healthy run replays it and creates the Night Card.
        let secondInvocation = EngineInvocation(
            act: .build, mode: .real, nightStart: nightCardNightStart, journal: journal,
            trigger: .forced, runID: RunID(), board: board, work: { _ in }
        )
        try await secondInvocation.run()
        #expect(try journal.pendingOutboxEntries().isEmpty)
        // One refused attempt, then the successful replay.
        #expect(await boards.writing.createIssueCalls == 2)
        #expect(await boards.writing.issues.count == 1)
    }

    @Test(".unreachable at preflight is not an authorization halt")
    func unreachableAtPreflightIsNotAnAuthorizationHalt() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let reading = FakeReadingBoard([])
        await reading.script(identity: .failure(.unreachable("timed out")))
        let board = ActBoard(reading: reading, writing: boards.writing, provisioning: boards.provisioning)
        let workRan = Mutex(false)

        let invocation = EngineInvocation(
            act: .build, mode: .real, nightStart: nightCardNightStart, journal: journal,
            trigger: .forced, runID: RunID(), board: board, work: { _ in workRan.withLock { $0 = true } }
        )

        try await invocation.run()

        #expect(workRan.withLock { $0 }, "a non-auth preflight failure is ignored; the Act proceeds")
        let events = try journal.events().map(\.type)
        #expect(!events.contains(.linearAuthorizationHalted))
    }
}
