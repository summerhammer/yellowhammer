import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
import Journal
import Synchronization
import Testing

// graph-execution/allocate-a-worktree-per-graph-and-repo, OQ123(c), glossary Exception Notification:
// a Worktree branch-name collision is a cause of *halted*, not a fourth event. It fires once per Project
// per Night; later Acts that hit it again only update the Night Card. Every Act appends
// `.worktreeNameCollision` and then `.actIncomplete`.

/// Records every notification a fake `ExceptionNotifier` was asked to post.
private final class CollisionNotificationRecorder: Sendable {
    private let storage = Mutex<[ExceptionNotification]>([])

    func record(_ notification: ExceptionNotification) {
        storage.withLock { $0.append(notification) }
    }

    var notifications: [ExceptionNotification] { storage.withLock { $0 } }
}

private struct UnrelatedFailure: Error, CustomStringConvertible {
    let description: String
}

@Suite("Worktree branch-name collision halt (B2.1)")
struct WorktreeNameCollisionHaltTests {
    private static let collision = BuildActError.worktreeNameCollision(
        repository: "yellowhammer", requested: "yh-yellowhammer-night-card",
        reported: "rozd/yh-yellowhammer-night-card"
    )

    private static func collidingInvocation(
        act: Act = .build, nightStart: NightStart = nightCardNightStart, journal: JournalStore,
        boards: NightCardTestBoards, recorder: CollisionNotificationRecorder
    ) -> EngineInvocation {
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        return EngineInvocation(
            act: act, mode: .real, nightStart: nightStart, journal: journal,
            trigger: .forced, runID: RunID(), board: board,
            notifier: ExceptionNotifier { recorder.record($0) },
            work: { _ in throw Self.collision }
        )
    }

    private static func haltedComments(_ boards: NightCardTestBoards) async -> [FakeWritingBoard.Comment] {
        await boards.writing.comments.filter { $0.body.hasPrefix("**Night halted:**") }
    }

    @Test("The first collision this Night appends the event before actIncomplete, comments, and posts halted")
    func firstCollisionNotifies() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let recorder = CollisionNotificationRecorder()

        await #expect(throws: BuildActError.self) {
            try await Self.collidingInvocation(journal: journal, boards: boards, recorder: recorder).run()
        }

        #expect(recorder.notifications.count == 1)
        let notification = try #require(recorder.notifications.first)
        guard case .halted(let reason) = notification.event else {
            Issue.record("expected .halted, got \(notification.event)")
            return
        }
        #expect(reason == Self.collision.description)
        #expect(reason.count <= 200)
        #expect(reason.contains("yellowhammer"))
        #expect(reason.contains("'yh-yellowhammer-night-card'"))
        #expect(reason.contains("'rozd/yh-yellowhammer-night-card'"))

        let comments = await Self.haltedComments(boards)
        #expect(comments.count == 1)
        #expect(comments.first?.body.contains(Self.collision.description) == true)

        let types = try journal.events().map(\.type)
        let collisionIndex = try #require(types.firstIndex(of: .worktreeNameCollision))
        let incompleteIndex = try #require(types.firstIndex(of: .actIncomplete))
        #expect(collisionIndex < incompleteIndex)

        let record = try #require(try journal.events(ofType: .worktreeNameCollision).first)
        guard case .worktreeNameCollision(let repository, let requested, let reported) = record.event else {
            Issue.record("expected .worktreeNameCollision, got \(record.event)")
            return
        }
        #expect(repository == "yellowhammer")
        #expect(requested == "yh-yellowhammer-night-card")
        #expect(reported == "rozd/yh-yellowhammer-night-card")
    }

    @Test("A second collision the same Night posts nothing, adds a Night Card comment, and records a second event")
    func secondCollisionSameNightOnlyComments() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let recorder = CollisionNotificationRecorder()

        for _ in 0..<2 {
            await #expect(throws: BuildActError.self) {
                try await Self.collidingInvocation(journal: journal, boards: boards, recorder: recorder).run()
            }
        }

        #expect(recorder.notifications.count == 1)
        #expect(await Self.haltedComments(boards).count == 2)
        #expect(try journal.events(ofType: .worktreeNameCollision).count == 2)
        #expect(try journal.events(ofType: .actIncomplete).count == 2)
        #expect(try journal.events(ofType: .notificationDeliveryFailed).isEmpty)
    }

    @Test("The next Night's first collision notifies again")
    func nextNightNotifiesAgain() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let recorder = CollisionNotificationRecorder()
        let nextNight = try #require(NightStart(rawValue: "2026-09-16"))

        for nightStart in [nightCardNightStart, nightCardNightStart, nextNight] {
            await #expect(throws: BuildActError.self) {
                try await Self.collidingInvocation(
                    nightStart: nightStart, journal: journal, boards: boards, recorder: recorder
                ).run()
            }
        }

        #expect(recorder.notifications.count == 2)
        let nightIDs = Set(try journal.events(ofType: .worktreeNameCollision).compactMap(\.nightID))
        #expect(nightIDs.count == 2)
        #expect(try journal.events(ofType: .worktreeNameCollision).count == 3)
    }

    @Test("After a collision posted, a later halt for a different cause the same Night still posts")
    func differentCauseLaterStillPosts() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let recorder = CollisionNotificationRecorder()

        await #expect(throws: BuildActError.self) {
            try await Self.collidingInvocation(journal: journal, boards: boards, recorder: recorder).run()
        }
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        let unrelated = EngineInvocation(
            act: .land, mode: .real, nightStart: nightCardNightStart, journal: journal,
            trigger: .forced, runID: RunID(), board: board,
            notifier: ExceptionNotifier { recorder.record($0) },
            work: { _ in throw UnrelatedFailure(description: "boom") }
        )
        await #expect(throws: UnrelatedFailure.self) { try await unrelated.run() }

        #expect(recorder.notifications.count == 2)
        guard case .halted(let reason) = recorder.notifications[1].event else {
            Issue.record("expected .halted, got \(recorder.notifications[1].event)")
            return
        }
        #expect(reason == "boom")
        #expect(try journal.events(ofType: .worktreeNameCollision).count == 1)
    }
}
