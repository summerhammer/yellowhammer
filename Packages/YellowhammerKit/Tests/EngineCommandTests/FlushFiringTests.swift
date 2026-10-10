import Config
import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
import Journal
import Synchronization
import Testing

// shift-scheduling/open-and-close-the-night-card (OQ155 (2), Transient Board Failure Ruling item 6, as
// amended by the Build Firing Offset Ruling item 2): three land firings after `night_end` deliver a
// completion left pending and close a Night the closing land failed to close. A flush firing does no
// Night work.

private final class Count: Sendable {
    private let storage = Mutex<Int>(0)
    func increment() { storage.withLock { $0 += 1 } }
    var value: Int { storage.withLock { $0 } }
}

private final class Posts: Sendable {
    private let storage = Mutex<[ExceptionNotification.Event]>([])
    func record(_ notification: ExceptionNotification) { storage.withLock { $0.append(notification.event) } }
    var events: [ExceptionNotification.Event] { storage.withLock { $0 } }
}

private final class FlushScene: Sendable {
    let fixture: NightCardJournalFixture
    let journal: JournalStore
    let boards: NightCardTestBoards
    let board: ActBoard
    let posts = Posts()
    let work = Count()

    init() async throws {
        fixture = try NightCardJournalFixture()
        journal = try fixture.open()
        boards = try await makeBoards()
        board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
    }

    /// An Act of the Night that leaves it open, as a closing land that died would have.
    func openTheNight() async throws {
        try await EngineInvocation(
            act: .build, mode: .real, nightStart: nightCardNightStart, journal: journal,
            trigger: .forced, runID: RunID(), board: board, work: { _ in }
        ).run()
    }

    /// The Night's closing land, forced so its trigger is met and it runs its work.
    func closingLand(sleeps: SleepLog = SleepLog()) async throws {
        try await EngineInvocation(
            act: .land, mode: .real, nightStart: nightCardNightStart, journal: journal,
            trigger: .forced, runID: RunID(), closesNight: true, board: board,
            outboxTransientRetry: sleeps.ruled, work: { _ in self.work.increment() }
        ).run()
    }

    func flushFiring(sleeps: SleepLog = SleepLog(), runID: RunID = RunID()) async throws {
        let posts = posts
        let work = work
        var invocation = EngineInvocation(
            act: .land, mode: .real, nightStart: nightCardNightStart, journal: journal,
            trigger: .scheduled, runID: runID, closesNight: true, board: board,
            notifier: ExceptionNotifier { posts.record($0) },
            outboxTransientRetry: sleeps.ruled, work: { _ in work.increment() }
        )
        invocation.isFlushFiring = true
        try await invocation.run()
    }

    func flushEvents() throws -> [FlushFiringOutcome] {
        try journal.events(ofType: .flushFiringRan).compactMap {
            if case .flushFiringRan(let outcome, _) = $0.event { outcome } else { nil }
        }
    }
}

@Suite("Flush firings after night_end")
struct FlushFiringTests {
    @Test("A flush firing closes a Night still open, with no land work, and says it did")
    func flushClosesAnOpenNight() async throws {
        let scene = try await FlushScene()
        try await scene.openTheNight()
        #expect(try scene.journal.currentNight() != nil)

        try await scene.flushFiring()

        let night = try #require(try scene.journal.night(nightStart: nightCardNightStart))
        #expect(night.state == .closed)
        #expect(night.closeReason == .nightEnd)
        #expect(scene.work.value == 0)
        #expect(try scene.flushEvents() == [.closedNight])
        let flushEvent = try #require(try scene.journal.events(ofType: .flushFiringRan).first)
        #expect(flushEvent.nightID == night.id)
        // The close goes through the same path as the closing land: completion through the Outbox, and the
        // `closed` notification, the flush firing being the closing Act.
        #expect(try scene.journal.events(ofType: .nightClosed).count == 1)
        #expect(try scene.journal.events(ofType: .nightCardCompleted).count == 1)
        #expect(try scene.journal.pendingOutboxEntries().isEmpty)
        #expect(scene.posts.events == [.closed])
        // No trigger evaluation and no Roll-up: nothing idle was recorded.
        #expect(try scene.journal.events(ofType: .actIdle).isEmpty)

        let issue = try #require(await scene.boards.writing.liveIssues.first)
        let description = try #require(issue.description)
        #expect(description.contains("closing land did not close it: a flush firing closed it at "))
        #expect(description.contains(flushEvent.occurredAt.formatted(.iso8601)))
    }

    @Test("A Night closed by its own closing land does not say a flush firing closed it")
    func closingLandSaysNothingOfFlush() async throws {
        let scene = try await FlushScene()
        try await scene.closingLand()

        let issue = try #require(await scene.boards.writing.liveIssues.first)
        #expect(try #require(issue.description).contains("flush firing") == false)
        #expect(try scene.flushEvents().isEmpty)
        #expect(scene.work.value == 1)
    }

    @Test("A flush firing on a closed Night delivers the pending completion and posts nothing")
    func flushDeliversAPendingCompletion() async throws {
        let scene = try await FlushScene()
        try await scene.openTheNight()
        let issue = try #require(try scene.journal.currentNight()?.nightCardIssueID)
        let target = BoardObjectID(rawValue: issue)
        await scene.boards.writing.refuse(issue: target, with: .unreachable("Linear answered with HTTP 503"))
        try await scene.closingLand()
        #expect(try scene.journal.pendingOutboxEntries().count == 2)
        #expect(try scene.journal.events(ofType: .nightCardCompleted).isEmpty)

        await scene.boards.writing.clearRefusal(issue: target)
        try await scene.flushFiring()

        #expect(try scene.journal.pendingOutboxEntries().isEmpty)
        #expect(try scene.journal.events(ofType: .nightCardCompleted).count == 1)
        #expect(try scene.flushEvents() == [.delivered])
        #expect(scene.posts.events.isEmpty)
        // The closing land's work ran once; the flush firing did none and closed nothing again.
        #expect(scene.work.value == 1)
        #expect(try scene.journal.events(ofType: .nightClosed).count == 1)
    }

    @Test("Linear still unreachable: three flush firings leave the entries pending, never failed")
    func flushLeavesEntriesPendingWhileLinearIsDown() async throws {
        let scene = try await FlushScene()
        try await scene.openTheNight()
        let issue = try #require(try scene.journal.currentNight()?.nightCardIssueID)
        await scene.boards.writing.refuse(issue: BoardObjectID(rawValue: issue), with: .unreachable("HTTP 503"))
        try await scene.closingLand()
        let before = try scene.journal.pendingOutboxEntries()
        #expect(before.count == 2)

        for _ in 0..<3 {
            try await scene.flushFiring()
        }

        let after = try scene.journal.pendingOutboxEntries()
        #expect(after.map(\.id) == before.map(\.id))
        #expect(after.allSatisfy { $0.state == .pending })
        // The flush firings' passes are not attempts: the entry is exactly as the closing land left it.
        #expect(after.map(\.attemptCount) == before.map(\.attemptCount))
        #expect(try scene.journal.events(ofType: .boardWriteFailed).isEmpty)
        #expect(try scene.journal.events(ofType: .nightCardCompleted).isEmpty)
        #expect(scene.posts.events.isEmpty)
        #expect(try scene.flushEvents() == [.stillPending, .stillPending, .stillPending])
    }

    @Test("A flush firing that fails on a closed Night records it as its own event, not as the Night halting")
    func flushFailureOnAClosedNightIsNotAHalt() async throws {
        let scene = try await FlushScene()
        try await scene.openTheNight()
        let issue = try #require(try scene.journal.currentNight()?.nightCardIssueID)
        let target = BoardObjectID(rawValue: issue)
        await scene.boards.writing.refuse(issue: target, with: .unreachable("HTTP 503"))
        try await scene.closingLand()
        await scene.boards.writing.refuse(issue: target, with: .notAuthenticated("token revoked"))

        try await scene.flushFiring()

        #expect(try scene.flushEvents() == [.failed])
        #expect(try scene.journal.events(ofType: .actIncomplete).isEmpty)
        #expect(scene.posts.events.isEmpty)
        #expect(try scene.journal.pendingOutboxEntries().count == 2)
        // The run is closed: it started and ended, and is not left looking like a crash.
        let flushRun = try #require(try scene.journal.events(ofType: .flushFiringRan).first?.runID)
        let types = try scene.journal.events().filter { $0.runID == flushRun }.map(\.type)
        #expect(types == [.actStarted, .flushFiringRan, .actEnded])
    }

    @Test("A flush firing for a Night with no Journal record opens no Night and no Night Card")
    func flushWithNoNightOpensNothing() async throws {
        let scene = try await FlushScene()

        try await scene.flushFiring()

        #expect(try scene.journal.night(nightStart: nightCardNightStart) == nil)
        #expect(try scene.journal.currentNight() == nil)
        #expect(await scene.boards.writing.liveIssues.isEmpty)
        #expect(try scene.flushEvents() == [.noNight])
        #expect(try scene.journal.events(ofType: .nightOpened).isEmpty)
        #expect(try scene.journal.events(ofType: .nightCardOpened).isEmpty)
        #expect(try scene.journal.events().allSatisfy { $0.nightID == nil })
        #expect(scene.work.value == 0)
        #expect(scene.posts.events.isEmpty)
    }

    @Test("A flush firing does not sweep an older open Night or run the absent-Night audit")
    func flushOpensNoSweep() async throws {
        let scene = try await FlushScene()
        let earlier = NightStart(rawValue: "2026-09-10")!
        try await EngineInvocation(
            act: .build, mode: .real, nightStart: earlier, journal: scene.journal,
            trigger: .forced, runID: RunID(), work: { _ in }
        ).run()

        try await scene.flushFiring()

        #expect(try scene.journal.events(ofType: .nightOpenedAndDied).isEmpty)
        #expect(try scene.journal.events(ofType: .absentNightDetected).isEmpty)
        #expect(try scene.journal.currentNight()?.nightStart == earlier)
    }

    @Test("A flush firing stands down on a held Lease and the next one closes the Night")
    func flushStandsDownOnTheLease() async throws {
        let scene = try await FlushScene()
        try await scene.openTheNight()
        let holder = RunID()
        _ = try scene.journal.claimActLease(act: .build, runID: holder, mode: .real, policy: .ruled)

        await #expect(throws: EngineInvocationError.self) {
            try await scene.flushFiring()
        }
        #expect(try scene.journal.currentNight() != nil)
        #expect(scene.work.value == 0)

        try scene.journal.releaseActLease(runID: holder)
        try await scene.flushFiring()
        #expect(try scene.journal.currentNight() == nil)
        #expect(try scene.flushEvents() == [.closedNight])
    }

    @Test("A Night that opened and died keeps its open Night Card: a flush firing does not complete it")
    func flushLeavesAnOpenedAndDiedNightAlone() async throws {
        let scene = try await FlushScene()
        try await scene.openTheNight()
        let night = try #require(try scene.journal.currentNight())
        let run = RunID()
        _ = try scene.journal.claimActLease(act: .author, runID: run, mode: .real, policy: .ruled)
        try scene.journal.closeNight(id: night.id, reason: .openedAndDied, act: .author, runID: run)
        try scene.journal.releaseActLease(runID: run)

        try await scene.flushFiring()

        #expect(try scene.journal.events(ofType: .nightCardCompleted).isEmpty)
        #expect(try scene.journal.pendingOutboxEntries().isEmpty)
        #expect(try scene.flushEvents() == [.nothingPending])
    }

    @Test("Without a flush firing, a land after night_end still runs its work and closes the Night")
    func closingLandRunsItsWork() async throws {
        let scene = try await FlushScene()
        try await scene.openTheNight()

        try await scene.closingLand()

        #expect(scene.work.value == 1)
        #expect(try scene.journal.currentNight() == nil)
        #expect(try scene.flushEvents().isEmpty)
    }
}

// MARK: - The clock decides

private func localDate(day: Int, hour: Int, minute: Int) throws -> Date {
    try #require(Calendar.current.date(from: DateComponents(
        year: 2026, month: 9, day: day, hour: hour, minute: minute
    )))
}

@Suite("Which land firing is a flush firing")
struct FlushFiringClassificationTests {
    private func command(_ arguments: [String]) throws -> LandCommand {
        try LandCommand.parse(arguments)
    }

    @Test("The land at night_end + o is the closing land, not a flush firing")
    func closingLandIsNotAFlushFiring() throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        let land = try command(["--project", "alpha"]) // glossary:ignore GL001

        for (hour, minute) in [(6, 0), (6, 14)] {
            let invocation = try land.makeInvocation(
                configurationDirectory: directory.url, now: try localDate(day: 16, hour: hour, minute: minute)
            )
            #expect(invocation.closesNight)
            #expect(!invocation.isFlushFiring)
        }
    }

    @Test("A scheduled land from the first flush minute on is a flush firing of that Night")
    func scheduledLandAfterTheBoundaryIsAFlushFiring() throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        let land = try command(["--project", "alpha"]) // glossary:ignore GL001

        for (hour, minute) in [(6, 15), (7, 0), (9, 0)] {
            let invocation = try land.makeInvocation(
                configurationDirectory: directory.url, now: try localDate(day: 16, hour: hour, minute: minute)
            )
            #expect(invocation.isFlushFiring)
            #expect(invocation.closesNight)
            #expect(invocation.nightStart == NightStart(rawValue: "2026-09-15"))
        }
    }

    @Test("The first flush minute follows the Project's Stagger Offset, by sorted Project id")
    func flushMinuteFollowsTheStaggerOffset() throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        try directory.writeValidProjectFile(id: "beta")
        let sixFifteen = try localDate(day: 16, hour: 6, minute: 15)
        let sixEighteen = try localDate(day: 16, hour: 6, minute: 18)

        // alpha is index 0 (offset 0), beta index 1 (offset 3): beta's first flush minute is 06:18.
        let alpha = try command(["--project", "alpha"]) // glossary:ignore GL001
        #expect(try alpha.makeInvocation(configurationDirectory: directory.url, now: sixFifteen).isFlushFiring)
        let beta = try command(["--project", "beta"]) // glossary:ignore GL001
        #expect(try !beta.makeInvocation(configurationDirectory: directory.url, now: sixFifteen).isFlushFiring)
        #expect(try beta.makeInvocation(configurationDirectory: directory.url, now: sixEighteen).isFlushFiring)
    }

    @Test("A land during the Night, or the next Night, is not a flush firing")
    func landInsideANightIsNotAFlushFiring() throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        let land = try command(["--project", "alpha"]) // glossary:ignore GL001

        for (day, hour) in [(15, 23), (16, 22), (17, 3)] {
            let invocation = try land.makeInvocation(
                configurationDirectory: directory.url, now: try localDate(day: day, hour: hour, minute: 30)
            )
            #expect(!invocation.isFlushFiring)
            #expect(!invocation.closesNight)
        }
    }

    @Test("A forced land after the boundary keeps today's closing behaviour")
    func forcedLandIsNotAFlushFiring() throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        let land = try command(["--project", "alpha", "--force"]) // glossary:ignore GL001

        let invocation = try land.makeInvocation(
            configurationDirectory: directory.url, now: try localDate(day: 16, hour: 7, minute: 0)
        )

        #expect(invocation.closesNight)
        #expect(!invocation.isFlushFiring)
    }

    @Test("A rehearsal land after the boundary, with or without --night, keeps today's closing behaviour")
    func rehearsalLandIsNotAFlushFiring() throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha", rehearsal: true)
        let late = try localDate(day: 16, hour: 7, minute: 0)

        let plain = try command(["--project", "alpha", "--rehearsal"]) // glossary:ignore GL001
        let rehearsal = try plain.makeInvocation(configurationDirectory: directory.url, now: late)
        #expect(rehearsal.closesNight)
        #expect(!rehearsal.isFlushFiring)

        let named = try command(["--project", "alpha", "--rehearsal", "--night", "2026-09-15"]) // glossary:ignore GL001
        let past = try named.makeInvocation(configurationDirectory: directory.url, now: late)
        #expect(past.closesNight)
        #expect(!past.isFlushFiring)
    }

    @Test("Build and author are never flush firings")
    func otherActsAreNotFlushFirings() throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        let late = try localDate(day: 16, hour: 7, minute: 0)

        let build = try BuildCommand.parse(["--project", "alpha"]) // glossary:ignore GL001
        #expect(try !build.makeInvocation(configurationDirectory: directory.url, now: late).isFlushFiring)
        let author = try AuthorCommand.parse(["--project", "alpha"]) // glossary:ignore GL001
        #expect(try !author.makeInvocation(configurationDirectory: directory.url, now: late).isFlushFiring)
    }
}
