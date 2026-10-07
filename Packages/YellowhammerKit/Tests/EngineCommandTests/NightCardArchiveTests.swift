import Domain
@testable import Engine
import Foundation
import Journal
import Testing

@Suite("Archived Night Cards are replaced without undoing the Operator's gesture")
struct NightCardArchiveTests {
    @Test("Two later Acts retain the archive, replay old pending writes safely and complete the replacement")
    // swiftlint:disable:next function_body_length
    func laterActsUseReplacement() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let reading = FakeReadingBoard([])
        try await reading.readThrough(boards)
        let board = ActBoard(reading: reading, writing: boards.writing, provisioning: boards.provisioning)
        try await EngineInvocation(
            act: .author, mode: .real, nightStart: nightCardNightStart, journal: journal,
            trigger: .forced, board: board, work: { context in
                let maintenance = try #require(context.nightCard)
                try await maintenance.recordAuthoring(night: context.night)
                _ = try await maintenance.acceptCompletion(night: context.night)
                let outbox = try #require(context.outbox)
                _ = try outbox.accept(OutboxWrite(key: "old-halt", write: .createComment(
                    issue: BoardObjectID(rawValue: try #require(context.night.nightCardIssueID)), body: "old halt"
                )))
                await boards.writing.refuseNext(.unreachable("leave old entries pending"))
            }
        ).run()
        let first = try #require(try journal.currentNight())
        let old = BoardObjectID(rawValue: try #require(first.nightCardIssueID))
        await boards.writing.edit(old, description: "Human prose\n" + fencedDescription)
        try await boards.writing.archiveIssue(old)
        let archived = try #require(await boards.writing.issue(old))
        let logCount = await boards.writing.writeLog.count
        try await EngineInvocation(
            act: .build, mode: .real, nightStart: nightCardNightStart, journal: journal,
            trigger: .forced, board: board, work: { context in
                #expect(context.night.nightCardIssueID != old.rawValue)
                try await #require(context.nightCard).recordAuthoring(night: first)
                _ = try await #require(context.outbox).deliverPending()
            }
        ).run()
        let replacement = try #require(try journal.currentNight()?.nightCardIssueID)
        let created = try #require(await boards.writing.issue(BoardObjectID(rawValue: replacement)))
        #expect(created.description?.contains("https://linear.app/issue/\(old.rawValue)") == true)
        try await EngineInvocation(
            act: .land, mode: .real, nightStart: nightCardNightStart, journal: journal,
            trigger: .forced, closesNight: true, board: board, work: { _ in }
        ).run()
        #expect(await boards.writing.createIssueCalls == 2)
        #expect(try journal.archivedNightCardIssueIDs(nightID: first.id) == [old.rawValue])
        #expect(try journal.night(id: first.id)?.nightCardIssueID == replacement)
        #expect(await boards.writing.writes(to: old, since: logCount).isEmpty)
        #expect(await boards.writing.issue(old) == archived)
        #expect(await boards.writing.comments.isEmpty)
        let completed = try #require(await boards.writing.issue(BoardObjectID(rawValue: replacement)))
        #expect(completed.description?.contains("**Completed:**") == true)
        #expect(completed.description?.contains("https://linear.app/issue/\(old.rawValue)") == true)
        let scope = try await NightCardScope.resolve(using: boards.provisioning)
        #expect(completed.workflowState == scope.completedState)
        #expect(try journal.pendingOutboxEntries().isEmpty)
    }

    @Test("Every archive generation is retained and a live current card is reused")
    func repeatedArchives() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let reading = FakeReadingBoard([])
        try await reading.readThrough(boards)
        let board = ActBoard(reading: reading, writing: boards.writing, provisioning: boards.provisioning)
        var predecessors: [String] = []
        for _ in 0..<3 {
            try await EngineInvocation(
                act: .build, mode: .real, nightStart: nightCardNightStart, journal: journal,
                trigger: .forced, board: board, work: { _ in }
            ).run()
            let id = try #require(try journal.currentNight()?.nightCardIssueID)
            predecessors.append(id)
            try await boards.writing.archiveIssue(BoardObjectID(rawValue: id))
        }
        for _ in 0..<2 {
            try await EngineInvocation(
                act: .build, mode: .real, nightStart: nightCardNightStart, journal: journal,
                trigger: .forced, board: board, work: { _ in }
            ).run()
        }
        let night = try #require(try journal.currentNight())
        #expect(try journal.archivedNightCardIssueIDs(nightID: night.id) == predecessors)
        #expect(await boards.writing.createIssueCalls == 4)
        #expect(await boards.writing.liveIssues.count == 1)
    }

    @Test("An applied replacement whose Night record was interrupted is recovered under the same client id")
    func appliedReplacementRecovery() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let reading = FakeReadingBoard([])
        try await reading.readThrough(boards)
        let run = RunID()
        _ = try journal.claimActLease(act: .build, runID: run, mode: .real)
        let initial = try journal.openNight(nightStart: nightCardNightStart, mode: .real, act: .build, runID: run).night
        let outbox = Outbox(journal: journal, board: boards.writing, reading: reading, runID: run, act: .build)
        let maintenance = NightCardMaintenance(journal: journal, outbox: outbox, provisioning: boards.provisioning)
        _ = try await maintenance.open(night: initial)
        let night = try #require(try journal.currentNight())
        let predecessor = try #require(night.nightCardIssueID)
        try await boards.writing.archiveIssue(BoardObjectID(rawValue: predecessor))
        let key = NightCardMaintenance.replacementKey(nightStart: night.nightStart, predecessor: predecessor)
        let scope = try await NightCardScope.resolve(using: boards.provisioning)
        let delivery = try await outbox.post(OutboxWrite(key: key, write: .createIssue(BoardIssueDraft(
            team: scope.team, title: "Night \(night.nightStart)",
            description: "Replaces [archived](https://linear.app/issue/\(predecessor))\n" + fencedDescription,
            labels: [scope.nightCardLabel]
        ), parentKey: nil)))
        guard case .applied(let id) = delivery.outcome else { Issue.record("expected applied create"); return }
        #expect(try journal.currentNight()?.nightCardIssueID == predecessor)
        _ = try await maintenance.open(night: night)
        _ = try await maintenance.open(night: night)
        #expect(try journal.currentNight()?.nightCardIssueID == id?.rawValue)
        #expect(await boards.writing.createIssueCalls == 2)
        #expect(try journal.archivedNightCardIssueIDs(nightID: night.id) == [predecessor])
    }

    @Test("Archived interrupted creates are retained and replaced on replay", arguments: [false, true])
    func archivedCreateReplay(replacement: Bool) async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let reading = FakeReadingBoard([])
        try await reading.readThrough(boards)
        let run = RunID()
        _ = try journal.claimActLease(act: .build, runID: run, mode: .real)
        var night = try journal.openNight(nightStart: nightCardNightStart, mode: .real, act: .build, runID: run).night
        if replacement {
            let outbox = Outbox(journal: journal, board: boards.writing, reading: reading, runID: run, act: .build)
            _ = try await NightCardMaintenance(
                journal: journal, outbox: outbox, provisioning: boards.provisioning
            ).open(night: night)
            night = try #require(try journal.currentNight())
            try await boards.writing.archiveIssue(BoardObjectID(rawValue: try #require(night.nightCardIssueID)))
        }
        let crashing = Outbox(
            journal: journal, board: boards.writing, reading: reading, runID: run, act: .build,
            interrupt: { _ in throw SimulatedCrash() }
        )
        let maintenance = NightCardMaintenance(journal: journal, outbox: crashing, provisioning: boards.provisioning)
        await #expect(throws: SimulatedCrash.self) { try await maintenance.open(night: night) }
        let interrupted = try #require(await boards.writing.liveIssues.first)
        try await boards.writing.archiveIssue(interrupted.id)
        try journal.releaseActLease(runID: run)
        let resumedRun = RunID()
        _ = try journal.claimActLease(act: .build, runID: resumedRun, mode: .real)
        let resumed = Outbox(
            journal: journal, board: boards.writing, reading: reading, runID: resumedRun, act: .build
        )
        _ = try await NightCardMaintenance(
            journal: journal, outbox: resumed, provisioning: boards.provisioning
        ).open(night: night)
        let current = try #require(try journal.currentNight())
        #expect(current.nightCardIssueID != interrupted.id.rawValue)
        let history = try journal.archivedNightCardIssueIDs(nightID: night.id)
        #expect(history.last == interrupted.id.rawValue)
        #expect(history.count == (replacement ? 2 : 1))
        #expect(await boards.writing.liveIssues.count == 1)
        #expect(await boards.writing.archivedIssues.count == history.count)
    }

    @Test("A forced build of a closed Night restores summary and completion to a fresh card")
    func closedNightForcedBuild() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let reading = FakeReadingBoard([])
        try await reading.readThrough(boards)
        let board = ActBoard(reading: reading, writing: boards.writing, provisioning: boards.provisioning)
        try await EngineInvocation(
            act: .land, mode: .real, nightStart: nightCardNightStart, journal: journal,
            trigger: .forced, closesNight: true, board: board, work: { _ in }
        ).run()
        let original = try #require(await boards.writing.liveIssues.first)
        try await boards.writing.archiveIssue(original.id)
        for act in [Act.author, .build] {
            try await EngineInvocation(
                act: act, mode: .real, nightStart: nightCardNightStart, journal: journal,
                trigger: .forced, board: board, work: { context in
                    if context.act == .author {
                        try await #require(context.nightCard).recordAuthoring(night: context.night)
                    }
                }
            ).run()
        }
        let replacement = try #require(await boards.writing.liveIssues.first)
        #expect(replacement.description?.contains("**Completed:**") == true)
        #expect(replacement.workflowState == original.workflowState)
        #expect(await boards.writing.createIssueCalls == 2)
        #expect(try journal.events(ofType: .nightClosed).count == 1)
    }

    @Test("Linear acceptance followed by archival is neither delivered nor remembered as a posted block")
    func archiveAfterAcceptance() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let reading = FakeReadingBoard([])
        try await reading.readThrough(boards)
        let run = RunID()
        _ = try journal.claimActLease(act: .build, runID: run, mode: .real)
        let outbox = Outbox(journal: journal, board: boards.writing, reading: reading, runID: run)
        let issue = await boards.writing.seed(issue: "night", description: fencedDescription)
        await boards.writing.archiveAfterNextUpdate()
        let delivery = try await outbox.post(OutboxWrite(key: "summary", write: .rewriteManagedBlock(
            issue: issue, rendered: "completed"
        )))
        guard case .aborted = delivery.outcome else { Issue.record("expected archive abort"); return }
        #expect(delivery.entry.state == .aborted)
        #expect(delivery.entry.sentAt == nil)
        #expect(try journal.events(ofType: .managedBlockWritten).isEmpty)
        #expect(try journal.managedBlockLastPostedHash(issueID: issue.rawValue) == nil)
    }
}
