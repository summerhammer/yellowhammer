import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
import Journal
import Synchronization
import Testing

// morning-report/notify-the-operator-of-exceptions, Transient Board Failure Ruling 2026-10-09 items 9-15
// (K = 2): a halt whose cause is Linear being unreachable pages the Operator only at the 2nd consecutive
// one of the Night, once per outage, and always on the Night-closing Act. The count is derived from the
// Journal (`.linearReached`, `.linearUnreachableHalted`), because every Act is a separate process.

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
    var events: [ExceptionNotification.Event] { notifications.map(\.event) }
}

private let outage = BoardError.unreachable("HTTP 503")

/// One Night's Acts against a healthy fake board whose failures are scripted per Act.
private final class OutageScene {
    let fixture: NightCardJournalFixture
    let journal: JournalStore
    let boards: NightCardTestBoards
    let recorder = NotificationRecorder()
    var nightStart = nightCardNightStart

    init() async throws {
        fixture = try NightCardJournalFixture()
        journal = try fixture.open()
        boards = try await makeBoards()
    }

    func board() -> ActBoard {
        ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
    }

    /// Runs one Act (one `yh` process) to completion, swallowing the error a halted Act rethrows.
    func act(
        _ act: Act = .build, board: ActBoard?? = nil, closesNight: Bool = false, flush: Bool = false,
        work: @escaping @Sendable (ActContext) async throws -> Void = { _ in }
    ) async {
        let recorder = recorder
        var invocation = EngineInvocation(
            act: act, mode: .real, nightStart: nightStart, journal: journal,
            trigger: flush ? .scheduled : .forced, runID: RunID(), closesNight: closesNight,
            board: board ?? self.board(),
            notifier: ExceptionNotifier { recorder.record($0) },
            outboxTransientRetry: .never,
            work: work
        )
        invocation.isFlushFiring = flush
        _ = try? await invocation.run()
    }

    /// An Act that reaches Linear and then halts on a 503 in its work (a Delta Read, say).
    func haltOnOutage() async {
        await act { _ in throw outage }
    }

    func haltedComments() async -> [String] {
        await boards.writing.comments.map(\.body).filter { $0.contains("Night halted") }
    }
}

@Suite("Linear unreachable halt (Transient Board Failure Ruling items 9-15)")
struct LinearUnreachableHaltTests {
    @Test("Only BoardError.unreachable, bare or inside a Delta Read, is the board-unreachable cause")
    func classifiesOnTheErrorObject() {
        #expect(outage.isLinearUnreachable)
        #expect(DeltaReadError.boardUnavailable(outage).isLinearUnreachable)
        let others: [BoardError] = [
            .notAuthenticated("x"), .rateLimited(retryAfter: nil, budget: nil), .scopeNotFound("x"),
            .forbidden("x"), .refused("x"), .unreadableResponse("x")
        ]
        for other in others {
            #expect(!other.isLinearUnreachable)
            #expect(!DeltaReadError.boardUnavailable(other).isLinearUnreachable)
        }
        #expect(!SampleWorkFailure(description: "HTTP 503 unreachable").isLinearUnreachable)
    }

    @Test("The 1st halt posts nothing but is recorded and commented; the 2nd posts once; the 3rd does not")
    func pagesOnlyAtTheSecondConsecutiveHalt() async throws {
        let scene = try await OutageScene()

        await scene.haltOnOutage()
        #expect(scene.recorder.notifications.isEmpty)
        #expect(try scene.journal.events(ofType: .linearUnreachableHalted).count == 1)
        #expect(try scene.journal.events(ofType: .actIncomplete).count == 1)
        #expect(await scene.haltedComments().count == 1)

        await scene.haltOnOutage()
        #expect(scene.recorder.notifications.count == 1)
        let first = try #require(scene.recorder.notifications.first)
        guard case .halted(let reason) = first.event else {
            Issue.record("expected .halted, got \(first.event)")
            return
        }
        #expect(reason.contains("503"))

        await scene.haltOnOutage()
        await scene.haltOnOutage()
        #expect(scene.recorder.notifications.count == 1, "once per outage")

        // Every halt stays recorded, whether or not it posted.
        #expect(try scene.journal.events(ofType: .linearUnreachableHalted).count == 4)
        #expect(try scene.journal.events(ofType: .actIncomplete).count == 4)
        #expect(await scene.haltedComments().count == 4)
    }

    @Test("A halt that wraps the unreachable board in a Delta Read error counts the same")
    func deltaReadWrapperCounts() async throws {
        let scene = try await OutageScene()

        await scene.act { _ in throw DeltaReadError.boardUnavailable(outage) }
        #expect(scene.recorder.notifications.isEmpty)
        await scene.act { _ in throw DeltaReadError.boardUnavailable(outage) }
        #expect(scene.recorder.notifications.count == 1)
    }

    @Test("A halt, a successful Act, a halt, a halt: a new outage pages again at its own 2nd")
    func aSuccessfulActResetsTheCount() async throws {
        let scene = try await OutageScene()

        await scene.haltOnOutage()
        await scene.haltOnOutage()
        #expect(scene.recorder.notifications.count == 1)

        await scene.act()
        await scene.haltOnOutage()
        #expect(scene.recorder.notifications.count == 1, "the 1st halt of the new outage posts nothing")
        await scene.haltOnOutage()
        #expect(scene.recorder.notifications.count == 2)
    }

    @Test("A halt, an Act that made no Linear request, a halt: no reset, so the 2nd halt posts")
    func anActWithNoBoardNeitherIncrementsNorResets() async throws {
        let scene = try await OutageScene()

        await scene.haltOnOutage()
        await scene.act(board: .some(nil))
        #expect(scene.recorder.notifications.isEmpty)
        await scene.haltOnOutage()
        #expect(scene.recorder.notifications.count == 1)
    }

    @Test("An Act that halted before reaching Linear still counts: two such Acts post at the 2nd")
    func haltBeforeThePreflightReadCounts() async throws {
        let scene = try await OutageScene()

        await scene.boards.provisioning.refuseNext(outage)
        await scene.act()
        await scene.boards.provisioning.refuseNext(outage)
        await scene.act()

        #expect(try scene.journal.events(ofType: .linearReached).isEmpty)
        #expect(try scene.journal.events(ofType: .linearUnreachableHalted).count == 2)
        #expect(scene.recorder.notifications.count == 1)
    }

    @Test("A 1st halt with no Night Card to record on posts no .haltedUnrecorded; the 2nd, at K, does")
    func noNightCardPostsNothingUntilTheSecondHalt() async throws {
        let scene = try await OutageScene()

        await scene.boards.provisioning.refuseNext(outage)
        await scene.act()
        #expect(scene.recorder.notifications.isEmpty)
        #expect(try scene.journal.events(ofType: .nightCardOpened).isEmpty)

        await scene.boards.provisioning.refuseNext(outage)
        await scene.act()
        #expect(scene.recorder.events == [.haltedUnrecorded])
    }

    @Test("A halt after a halted comment write that cannot be recorded posts no .haltedUnrecorded below K")
    func abortedCommentBelowKPostsNothing() async throws {
        let scene = try await OutageScene()
        let comment = "**Night halted:** the `build` Act did not complete: \(outage)"
        await scene.boards.writing.script(.refuse(.notAuthenticated("no token")), for: comment)

        await scene.haltOnOutage()

        #expect(scene.recorder.notifications.isEmpty)
    }

    @Test("A pending halted comment still counts as recorded: the 2nd halt posts the ordinary .halted")
    func deferredCommentAtKPostsOrdinaryHalted() async throws {
        let scene = try await OutageScene()

        await scene.haltOnOutage()
        let comment = "**Night halted:** the `build` Act did not complete: \(outage)"
        await scene.boards.writing.script(.refuse(outage), for: comment)
        await scene.haltOnOutage()

        guard case .halted = try #require(scene.recorder.events.first) else {
            Issue.record("expected .halted, got \(scene.recorder.events)")
            return
        }
        #expect(scene.recorder.notifications.count == 1)
    }

    @Test("An authorization halt in between neither increments nor resets")
    func authorizationHaltIsNeutral() async throws {
        let scene = try await OutageScene()

        await scene.haltOnOutage()
        let unauthorized = FakeReadingBoard([])
        await unauthorized.script(identity: .failure(.notAuthenticated("sign-in expired")))
        await scene.act(board: ActBoard(
            reading: unauthorized, writing: scene.boards.writing, provisioning: scene.boards.provisioning
        ))
        #expect(scene.recorder.notifications.count == 1, "the authorization halt's own first-of-the-Night post")

        await scene.haltOnOutage()
        #expect(scene.recorder.notifications.count == 2, "the 2nd board-unreachable halt posts")
        let second = try #require(scene.recorder.notifications.last)
        guard case .halted(let reason) = second.event else {
            Issue.record("expected .halted, got \(second.event)")
            return
        }
        #expect(reason.contains("503"))
    }

    @Test("A halt for another cause posts every time, and resets the count because that Act reached Linear")
    func otherCausesPostEveryTimeAndReset() async throws {
        let scene = try await OutageScene()

        await scene.haltOnOutage()
        await scene.act { _ in throw SampleWorkFailure(description: "boom") }
        await scene.act { _ in throw SampleWorkFailure(description: "boom again") }
        #expect(scene.recorder.notifications.count == 2)

        await scene.haltOnOutage()
        #expect(scene.recorder.notifications.count == 2, "the count restarted at the other halts")
    }

    @Test("The count reads only this Night's events")
    func anotherNightsHaltsDoNotCount() async throws {
        let scene = try await OutageScene()

        await scene.haltOnOutage()
        scene.nightStart = try #require(NightStart(rawValue: "2026-09-16"))
        await scene.haltOnOutage()

        #expect(scene.recorder.notifications.isEmpty)
    }

    @Test("A Night-closing land halting on its 1st board-unreachable halt posts, saying the Night is not closed")
    func closingLandAlwaysPostsAndSaysNotClosed() async throws {
        let scene = try await OutageScene()

        await scene.act(.land, closesNight: true) { _ in throw outage }

        let notification = try #require(scene.recorder.notifications.first)
        #expect(scene.recorder.notifications.count == 1)
        guard case .haltedNightOpen(let reason) = notification.event else {
            Issue.record("expected .haltedNightOpen, got \(notification.event)")
            return
        }
        #expect(reason.contains("503"))
        #expect(notification.body.contains("not closed"))
        #expect(notification.body.contains("Night Card is not updated"))
        #expect(try scene.journal.night(nightStart: nightCardNightStart)?.isOpen == true)
        #expect(await scene.haltedComments().count == 1, "the halted comment is still written")
    }

    @Test("A Night-closing land halting before it reaches Linear still posts")
    func closingLandHaltingAtThePreflightPosts() async throws {
        let scene = try await OutageScene()

        await scene.boards.provisioning.refuseNext(outage)
        await scene.act(.land, closesNight: true)

        guard case .haltedNightOpen = try #require(scene.recorder.events.first) else {
            Issue.record("expected .haltedNightOpen, got \(scene.recorder.events)")
            return
        }
    }

    @Test("A flush firing that closes a still-open Night posts on its halt, saying the Night is not closed")
    func flushFiringClosingTheNightAlwaysPosts() async throws {
        let scene = try await OutageScene()
        await scene.act()
        #expect(scene.recorder.notifications.isEmpty)

        await scene.boards.provisioning.refuseNext(outage)
        await scene.act(.land, closesNight: true, flush: true)

        guard case .haltedNightOpen = try #require(scene.recorder.events.first) else {
            Issue.record("expected .haltedNightOpen, got \(scene.recorder.events)")
            return
        }
        #expect(scene.recorder.notifications.count == 1)
        #expect(try scene.journal.events(ofType: .linearUnreachableHalted).count == 1)
    }

    @Test("A flush firing on an already-closed Night posts nothing")
    func flushFiringOnAClosedNightPostsNothing() async throws {
        let scene = try await OutageScene()
        await scene.act(.land, closesNight: true)
        let postsBefore = scene.recorder.notifications.count

        await scene.boards.writing.refuseNext(outage)
        await scene.act(.land, closesNight: true, flush: true)

        #expect(scene.recorder.notifications.count == postsBefore)
    }
}
