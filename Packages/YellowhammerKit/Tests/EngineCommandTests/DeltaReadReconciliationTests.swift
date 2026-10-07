import Domain
import Foundation
import GRDB
import Testing

@testable import Engine
@testable import Journal

// board-projection/read-board-changes-by-delta: each Act reads what changed since the last read in one
// request; Yellowhammer's own comments are filtered by identity; Shelved is read and never written;
// deleted or re-stated Cards are reconciled against the Journal, which stays authoritative; a Card
// moved to another repository is reported rather than dispatched; a rate-budget refusal degrades the
// read and is recorded as installation-wide. These run against an in-memory Linear stand-in.

@Suite("Delta Read reconciliation")
struct DeltaReadReconciliationTests {
    // MARK: - Authoring invariant

    @Test("A Card moved to another repository on its Managed Block is reported, not dispatched against")
    func repositoryMoveBreaksInvariant() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        try insertCard(journal, issueID: "card-1", repository: "backend")
        try insertCard(journal, issueID: "card-2", repository: "backend")
        try insertCard(journal, issueID: "card-3", repository: "backend")
        let board = FakeReadingBoard([
            page(objects: [
                object("card-1", state: stateTodo, description: fenced(block: "**Repository:** `mobile`\nbrief")),
                object("card-2", state: stateTodo, description: fenced(block: "- Repository: backend\nbrief")),
                object("card-3", state: stateTodo, description: fenced(block: "Kind: impl\nno repository line"))
            ])
        ])
        let (read, _) = try deltaRead(journal, board: board, repositories: ["backend", "web"])

        guard case .read(let report) = try await read.perform() else {
            Issue.record("expected a read")
            return
        }

        #expect(report.invariantBreaks.map(\.card.issueID) == ["card-1"])
        #expect(report.invariantBreaks[0].reason.contains("'mobile'"))
        #expect(report.cardChanges.map(\.repositoryOnBoard) == ["mobile", "backend", nil])
        #expect(try journal.events(ofType: .authoringInvariantBroken).count == 1)
    }

    @Test("A repository outside the Project's Repos breaks the invariant even when the Journal agrees")
    func repositoryOutsideProject() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        try insertCard(journal, issueID: "card-1", repository: "legacy")
        let board = FakeReadingBoard([
            page(objects: [object("card-1", state: stateTodo, description: fenced(block: "Repository: legacy"))])
        ])
        let (read, _) = try deltaRead(journal, board: board, repositories: ["backend"])

        guard case .read(let report) = try await read.perform() else {
            Issue.record("expected a read")
            return
        }

        #expect(report.invariantBreaks.map(\.reason) == [
            "the Card's board copy names repository 'legacy', which is not a Repo of this Project"
        ])
    }

    // MARK: - Operator edits to the description

    @Test("Edits inside the Managed Block, outside it, and broken delimiters are each told apart")
    func descriptionEditsSurfaced() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        for issue in ["untouched", "block-edited", "prose-edited", "broken"] {
            try insertCard(journal, issueID: issue)
            try journal.recordManagedBlockPosted(issueID: issue, hash: ManagedBlockFence.sha256("posted block"))
            try journal.append(.managedBlockWritten(
                issueID: issue,
                preservedProseHash: ManagedBlockFence.sha256(
                    "prose\n\(ManagedBlockFence.start)\(ManagedBlockFence.end)"
                ),
                renderedHash: ManagedBlockFence.sha256("posted block")
            ))
        }
        let board = FakeReadingBoard([
            page(objects: [
                object("untouched", state: stateTodo, description: fenced(block: "posted block", prose: "prose\n")),
                object("block-edited", state: stateTodo, description: fenced(block: "edited block", prose: "prose\n")),
                object(
                    "prose-edited", state: stateTodo, description: fenced(block: "posted block", prose: "new prose\n")
                ),
                object("broken", state: stateTodo, description: "prose\n\(ManagedBlockFence.start)\nposted block")
            ])
        ])
        let (read, _) = try deltaRead(journal, board: board)

        guard case .read(let report) = try await read.perform() else {
            Issue.record("expected a read")
            return
        }

        let byIssue = Dictionary(uniqueKeysWithValues: report.cardChanges.map { ($0.card.issueID, $0) })
        #expect(byIssue["untouched"]?.hasOperatorSignal == false)
        #expect(byIssue["block-edited"]?.managedBlockEdited == true)
        #expect(byIssue["block-edited"]?.proseEdited == false)
        #expect(byIssue["prose-edited"]?.managedBlockEdited == false)
        #expect(byIssue["prose-edited"]?.proseEdited == true)
        #expect(byIssue["broken"]?.delimitersBroken == .endMissing)
        #expect(Set(report.operatorEdits.map(\.card.issueID)) == ["block-edited", "prose-edited", "broken"])
    }

    // MARK: - Rate budget

    @Test("A rate-limit refusal degrades the read: nothing is acted on, the sync point stays, installation-wide")
    func rateLimitDegrades() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let cardID = try insertCard(journal, issueID: "card-1", state: .todo)
        let board = FakeReadingBoard([
            page(
                objects: [object("card-1", state: stateShelved, updatedAt: 1)],
                nextObjectCursor: BoardCursor(rawValue: "o-2")
            ),
            .failure(.rateLimited(retryAfter: .seconds(30), budget: nil))
        ])
        let (read, _) = try deltaRead(journal, board: board)

        guard case .degraded(let reason) = try await read.perform() else {
            Issue.record("expected a degraded read")
            return
        }

        #expect(reason.contains("2 request(s)"))
        let state = try journal.card(id: cardID).state
        #expect(state == .todo, "a Shelved seen on a page before the refusal is not applied")
        #expect(try journal.boardSyncPoint() == nil)
        let events = try journal.events(ofType: .rateBudgetExhausted)
        #expect(events.count == 1)
        if case .rateBudgetExhausted(let degradation, _)? = events.first?.event {
            #expect(degradation.contains("nothing read this Act is acted on"))
        }
        #expect(events.first?.event.payload?["budget"] == "installation-wide")
        #expect(try journal.events(ofType: .deltaReadCompleted).isEmpty)
    }

    @Test("A degraded read names the Delta Read's Board Connection and workspace when it has one")
    func rateLimitNamesTheInstallation() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let board = FakeReadingBoard([.failure(.rateLimited(retryAfter: nil, budget: nil))])
        let label = AppInstallationLabel(name: "acme", workspace: BoardObjectID(rawValue: "workspace-1"))
        let (read, _) = try deltaRead(journal, board: board, installation: label)

        _ = try await read.perform()

        let event = try #require(try journal.events(ofType: .rateBudgetExhausted).first?.event)
        guard case .rateBudgetExhausted(_, let recorded) = event else {
            Issue.record("Event is not rateBudgetExhausted")
            return
        }
        #expect(recorded == label)
        #expect(event.payload?["installation"] == "acme")
        #expect(event.payload?["workspace"] == "workspace-1")
    }

    @Test("A board that cannot be reached fails the read rather than acting on nothing")
    func unreachableThrows() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let board = FakeReadingBoard([.failure(.unreachable("offline"))])
        let (read, _) = try deltaRead(journal, board: board)

        await #expect(throws: DeltaReadError.boardUnavailable(.unreachable("offline"))) {
            try await read.perform()
        }
        #expect(try journal.boardSyncPoint() == nil)
    }

    @Test("A run that lost the Project's lease cannot record the read")
    func staleRunCannotRecord() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let clock = ManualClock()
        let board = FakeReadingBoard([page(objects: [object("f-1", state: stateTodo, updatedAt: 1)])])
        let (read, _) = try deltaRead(journal, board: board, clock: clock)
        clock.advance(by: 601)

        await #expect(throws: JournalError.self) {
            try await read.perform()
        }
        #expect(try journal.boardSyncPoint() == nil)
    }

    // MARK: - Repository line parsing

    @Test("The Managed Block's repository line is read with or without markdown emphasis")
    func repositoryLineParsing() {
        #expect(DeltaRead.repository(inBlock: "**Repository:** `backend`") == "backend")
        #expect(DeltaRead.repository(inBlock: "Kind: impl\n- **Repository**: backend\nDoD") == "backend")
        #expect(DeltaRead.repository(inBlock: "repository: yellowhammer-web ") == "yellowhammer-web")
        #expect(DeltaRead.repository(inBlock: "Repository:") == nil)
        #expect(DeltaRead.repository(inBlock: "The repository is elsewhere") == nil)
        #expect(DeltaRead.repository(inBlock: "") == nil)
    }
}
