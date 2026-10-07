import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
import Journal
import Synchronization
import Testing

// Every Act resolves the Project's board scope before it creates the Night Card or does any work
// (spec rulings OQ85, OQ136; issue #353): the four provisioned `started` workflow states, the
// `Card Type` and `Block Reason` label groups with their children, and the `Override` group. An
// unresolved item halts the Act with one Journal event naming it, `.actIncomplete`, and the local
// *halted* notification — once per Night.

private struct SampleWorkFailure: Error, CustomStringConvertible, Equatable {
    let description: String
}

private final class NotificationRecorder: Sendable {
    private let storage = Mutex<[ExceptionNotification]>([])

    func record(_ notification: ExceptionNotification) {
        storage.withLock { $0.append(notification) }
    }

    var notifications: [ExceptionNotification] { storage.withLock { $0 } }

    /// The reasons of the *halted* notifications, in post order.
    var haltedReasons: [String] {
        notifications.compactMap { notification in
            guard case .halted(let reason) = notification.event else { return nil }
            return reason
        }
    }
}

/// One member of the board scope, how to take it off a complete board, and how a refusal names it.
enum BoardScopeItem: CaseIterable, CustomTestStringConvertible, Sendable {
    case waitingOnYou, blocked, keptInFlight, abandoned, cardTypeGroup, blockReasonChild, overrideGroup

    var testDescription: String { name }

    var name: String {
        switch self {
        case .waitingOnYou: BoardProvisioner.waitingOnYouState
        case .blocked: BoardProvisioner.blockedState
        case .keptInFlight: SettleValue.keptInFlight.rawValue
        case .abandoned: SettleValue.abandoned.rawValue
        case .cardTypeGroup: BoardProvisioner.cardTypeGroup
        case .blockReasonChild: BoardProvisioner.blockReasonChildren[0]
        case .overrideGroup: BoardProvisioner.overrideGroup
        }
    }

    /// The item as `yh setup` and `yh doctor` name it.
    var item: String {
        switch self {
        case .waitingOnYou, .blocked, .keptInFlight, .abandoned: "workflow state `\(name)` (team ENG)"
        case .cardTypeGroup, .overrideGroup: "group label `\(name)` (team ENG)"
        case .blockReasonChild: "label `\(name)` in group `Block Reason` (team ENG)"
        }
    }

    func remove(from board: FakeProvisioningBoard) async {
        switch self {
        case .waitingOnYou, .blocked, .keptInFlight, .abandoned:
            await board.remove(state: name, team: teamID)
        case .cardTypeGroup, .blockReasonChild, .overrideGroup:
            await board.remove(label: name, team: teamID)
        }
    }
}

private func invocation(
    _ act: Act, journal: JournalStore, boards: NightCardTestBoards, recorder: NotificationRecorder,
    nightStart: NightStart = nightCardNightStart, work: @escaping EngineInvocation.ActWork = { _ in }
) -> EngineInvocation {
    EngineInvocation(
        act: act, mode: .real, nightStart: nightStart, journal: journal, trigger: .forced, runID: RunID(),
        board: ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning),
        notifier: ExceptionNotifier { recorder.record($0) }, work: work
    )
}

@Suite("Board scope preflight (OQ85, OQ136)")
struct BoardScopePreflightTests {
    @Test("A missing Blocked state halts before the Night Card and work, records once, and posts once")
    func missingBlockedRefusesBeforeAnyWork() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        await BoardScopeItem.blocked.remove(from: boards.provisioning)
        let recorder = NotificationRecorder()
        let workRan = Mutex(false)

        let refusal = await #expect(throws: BoardScopeUnresolved.self) {
            try await invocation(
                .build, journal: journal, boards: boards, recorder: recorder,
                work: { _ in workRan.withLock { $0 = true } }
            ).run()
        }

        #expect(refusal?.items == [BoardScopeItem.blocked.item])
        #expect(!workRan.withLock { $0 })
        #expect(await boards.writing.createIssueCalls == 0, "no Night Card create was attempted")
        let records = try journal.events()
        #expect(records.map(\.type) == [.nightOpened, .actStarted, .boardScopeUnresolved, .actIncomplete])
        let recorded = try #require(records.first { $0.type == .boardScopeUnresolved })
        guard case .boardScopeUnresolved(let steps) = recorded.event else {
            Issue.record("expected .boardScopeUnresolved")
            return
        }
        #expect(steps.contains("workflow state `Blocked` (team ENG) is missing"))

        let reason = try #require(recorder.haltedReasons.first)
        #expect(recorder.notifications.count == 1)
        #expect(reason.contains("workflow state `Blocked` (team ENG)"))
        #expect(reason.count <= 200, "a one-item copy is never cut")
    }

    @Test("A second Act the same Night records its own event and posts nothing; the next Night posts again")
    func notificationIsOncePerNight() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        await BoardScopeItem.blocked.remove(from: boards.provisioning)
        let recorder = NotificationRecorder()

        await #expect(throws: BoardScopeUnresolved.self) {
            try await invocation(.author, journal: journal, boards: boards, recorder: recorder).run()
        }
        await #expect(throws: BoardScopeUnresolved.self) {
            try await invocation(.build, journal: journal, boards: boards, recorder: recorder).run()
        }

        #expect(try journal.events(ofType: .boardScopeUnresolved).count == 2)
        #expect(try journal.events(ofType: .actIncomplete).count == 2)
        #expect(recorder.notifications.count == 1)

        await #expect(throws: BoardScopeUnresolved.self) {
            try await invocation(
                .author, journal: journal, boards: boards, recorder: recorder,
                nightStart: NightStart(rawValue: "2026-09-16")!
            ).run()
        }
        #expect(recorder.notifications.count == 2)
    }

    @Test("After a refusal, a different-cause halt the same Night still posts")
    func laterDifferentCauseHaltStillPosts() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        await BoardScopeItem.blocked.remove(from: boards.provisioning)
        let recorder = NotificationRecorder()

        await #expect(throws: BoardScopeUnresolved.self) {
            try await invocation(.author, journal: journal, boards: boards, recorder: recorder).run()
        }
        #expect(recorder.notifications.count == 1)

        // The Operator fixes the board; a later Act then halts on something else entirely.
        await boards.provisioning.seed(state: BoardProvisioner.blockedState, team: teamID, category: .started)
        let failure = SampleWorkFailure(description: "boom")
        await #expect(throws: SampleWorkFailure.self) {
            try await invocation(
                .land, journal: journal, boards: boards, recorder: recorder, work: { _ in throw failure }
            ).run()
        }

        #expect(recorder.notifications.count == 2)
        let reason = try #require(recorder.haltedReasons.last)
        #expect(reason.contains("boom"))
        #expect(!reason.contains("board scope"))
    }

    @Test("Every scope item, missing, refuses the Act and names that item", arguments: BoardScopeItem.allCases)
    func eachMissingItemRefuses(item: BoardScopeItem) async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        await item.remove(from: boards.provisioning)
        let recorder = NotificationRecorder()
        let workRan = Mutex(false)

        let refusal = await #expect(throws: BoardScopeUnresolved.self) {
            try await invocation(
                .author, journal: journal, boards: boards, recorder: recorder,
                work: { _ in workRan.withLock { $0 = true } }
            ).run()
        }

        #expect(refusal?.items == [item.item])
        #expect(!workRan.withLock { $0 })
        #expect(await boards.writing.createIssueCalls == 0)
        #expect(recorder.haltedReasons.count == 1)
        #expect(recorder.haltedReasons.first?.contains(item.item) == true)
    }

    @Test("A same-name state of another category is a collision: refused, never guessed by name")
    func sameNameStateOfAnotherCategoryIsRefused() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        await BoardScopeItem.waitingOnYou.remove(from: boards.provisioning)
        await boards.provisioning.seed(state: BoardProvisioner.waitingOnYouState, team: teamID, category: .unstarted)
        let recorder = NotificationRecorder()

        let refusal = await #expect(throws: BoardScopeUnresolved.self) {
            try await invocation(.build, journal: journal, boards: boards, recorder: recorder).run()
        }

        #expect(refusal?.items == [BoardScopeItem.waitingOnYou.item])
        #expect(refusal?.steps.first?.contains("its name is held by") == true)
        #expect(await boards.writing.createIssueCalls == 0)
        #expect(recorder.haltedReasons.count == 1)
    }

    @Test("Once the missing item is provisioned, the next Act the same Night runs normally")
    func provisioningTheItemLetsTheNextActRun() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        await BoardScopeItem.keptInFlight.remove(from: boards.provisioning)
        let recorder = NotificationRecorder()

        await #expect(throws: BoardScopeUnresolved.self) {
            try await invocation(.author, journal: journal, boards: boards, recorder: recorder).run()
        }
        #expect(await boards.writing.createIssueCalls == 0)

        await boards.provisioning.seed(
            state: SettleValue.keptInFlight.rawValue, team: teamID, category: .started
        )
        let workRan = Mutex(false)
        try await invocation(
            .build, journal: journal, boards: boards, recorder: recorder,
            work: { _ in workRan.withLock { $0 = true } }
        ).run()

        #expect(workRan.withLock { $0 })
        #expect(await boards.writing.createIssueCalls == 1, "the Night Card is created by the Act that ran")
        #expect(try journal.currentNight()?.nightCardIssueID != nil)
        #expect(recorder.notifications.count == 1, "only the refusal posted")
    }

    @Test("A sibling Project with a complete board is unaffected by this Project's refusal")
    func siblingProjectsAreIndependent() async throws {
        let incompleteFixture = try NightCardJournalFixture(project: "alpha")
        let completeFixture = try NightCardJournalFixture(project: "beta")
        let incompleteJournal = try incompleteFixture.open()
        let completeJournal = try completeFixture.open()
        let incompleteBoards = try await makeBoards()
        let completeBoards = try await makeBoards()
        await BoardScopeItem.overrideGroup.remove(from: incompleteBoards.provisioning)
        let recorder = NotificationRecorder()
        let workRan = Mutex(false)

        await #expect(throws: BoardScopeUnresolved.self) {
            try await invocation(.build, journal: incompleteJournal, boards: incompleteBoards, recorder: recorder)
                .run()
        }
        try await invocation(
            .build, journal: completeJournal, boards: completeBoards, recorder: recorder,
            work: { _ in workRan.withLock { $0 = true } }
        ).run()

        #expect(workRan.withLock { $0 })
        #expect(await completeBoards.writing.createIssueCalls == 1)
        #expect(try completeJournal.events(ofType: .boardScopeUnresolved).isEmpty)
        #expect(await incompleteBoards.writing.createIssueCalls == 0)
        #expect(try incompleteJournal.events(ofType: .boardScopeUnresolved).count == 1)
        let alpha = try #require(ProjectID(rawValue: "alpha"))
        #expect(recorder.notifications.map(\.project) == [alpha])
    }

    @Test("The preflight and yh doctor name the same missing item with the same message")
    func preflightAndDoctorAgree() async throws {
        let doctorFixture = try await DoctorLinearFixture()
        await doctorFixture.acme.remove(state: SettleValue.keptInFlight.rawValue, team: engineeringTeam.id)
        let journalFixture = try NightCardJournalFixture()
        let journal = try journalFixture.open()
        let writing = FakeWritingBoard()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: writing, provisioning: doctorFixture.acme)

        let refusal = await #expect(throws: BoardScopeUnresolved.self) {
            try await EngineInvocation(
                act: .build, mode: .real, nightStart: nightCardNightStart, journal: journal, trigger: .forced,
                runID: RunID(), board: board, work: { _ in }
            ).run()
        }
        let findings = await doctorFixture.doctor(projectFilter: ProjectID(rawValue: "alpha")).run()

        let failures = findings.linear("acme", subject: "provisioning").filter { $0.severity == .failure }
        let steps = try #require(refusal?.steps)
        #expect(steps.count == 1)
        #expect(failures.count == 1)
        let step = try #require(steps.first)
        #expect(step.contains(BoardScopeItem.keptInFlight.item))
        #expect(try #require(failures.first).message.hasSuffix(step))
    }
}
