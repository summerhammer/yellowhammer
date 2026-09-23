import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
@testable import Journal
import Repositories
import Testing

@Suite("Night Summary: Project instrumented rates (P12.2)")
struct NightSummaryInstrumentedRatesTests {
    private struct SeededIDs {
        let feature: Int64
        let cycle: Int64
        let first: Int64
        let second: Int64
    }

    @Test("The first Act proves an empty opening before authoring creates work")
    func firstActOpeningScan() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(
            reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning
        )
        let start = try #require(NightStart(rawValue: "2026-09-25"))
        try await EngineInvocation(
            act: .author, mode: .real, nightStart: start, journal: journal,
            trigger: .forced, runID: RunID(), board: board, work: { _ in }
        ).run()
        #expect(try journal.provenEmptyOpeningCount(through: start) == 1)
    }

    @Test("Opening Ready observations distinguish empty, non-ready Todo, ready, and read failure")
    func openingReadyStatesAcrossNights() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let readiness = ReadinessCheck(
            provenance: FakeProvenanceTester(), citations: FakeCitationResolver()
        )
        let starts = try ["2026-09-25", "2026-09-26", "2026-09-27", "2026-09-28"].map {
            try #require(NightStart(rawValue: $0))
        }
        let cards = [openingBoardObject("CARD-1"), openingBoardObject("CARD-2"), openingBoardObject("CARD-3")]

        func runNight(_ start: NightStart, pages: [Result<BoardPage, BoardError>]) async throws {
            let reading = FakeReadingBoard([])
            await reading.scriptObjectPages(pages)
            let board = ActBoard(reading: reading, writing: boards.writing, provisioning: boards.provisioning)
            try await EngineInvocation(
                act: .author, mode: .real, nightStart: start, journal: journal, trigger: .forced,
                runID: RunID(), board: board, repositories: readinessRepositories,
                openingReadiness: readiness, work: { _ in }
            ).run()
        }

        try await runNight(starts[0], pages: [.success(BoardPage(objects: [], nextCursor: nil))])
        let ids = try seedCards(journal, at: Date())
        try await runNight(starts[1], pages: [.success(BoardPage(objects: cards, nextCursor: nil))])
        try journal.recordArchitecturalBrief(cardID: ids.first, prose: "A concrete brief")
        try journal.insertClause(.init(
            cid: "c1", issueID: "CARD-1", level: "card", text: "Build it", locationID: "resolvable/story",
            provenance: "machine-found", citationProvenance: "machine-found"
        ))
        try await runNight(starts[2], pages: [.success(BoardPage(objects: cards, nextCursor: nil))])
        try await runNight(starts[3], pages: [.failure(.unreachable("board read failed"))])

        let nights = try journal.nights()
        #expect(try journal.openingReadyState(nightID: nights[0].id) == .zero)
        #expect(try journal.openingReadyState(nightID: nights[1].id) == .zero)
        #expect(try journal.openingReadyState(nightID: nights[2].id) == .nonzero)
        #expect(try journal.openingReadyState(nightID: nights[3].id) == .unknown)
        #expect(try journal.openingReadyCounts(through: starts[3]) == .init(zero: 2, nonzero: 1, unknown: 1))
        #expect(try journal.currentCardLease(cardID: ids.first) == nil)
        #expect(try journal.events(ofType: .readinessCheckPassed).isEmpty)
    }

    private func openingBoardObject(_ issueID: String) -> BoardObject {
        BoardObject(
            id: BoardObjectID(rawValue: issueID), key: issueID, title: issueID, description: nil,
            workflowState: BoardWorkflowState(id: BoardObjectID(rawValue: "todo"), name: "Todo"),
            labels: ["Card"], parent: nil, url: "https://example.test/\(issueID)",
            createdAt: Date(), updatedAt: Date()
        )
    }

    @Test("Board edits affect the read-only opening judgement without changing the Journal")
    func boardEditedCitationIsNotReady() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let ids = try seedCards(journal, at: Date())
        try journal.recordArchitecturalBrief(cardID: ids.first, prose: "A concrete brief")
        try journal.insertClause(.init(
            cid: "c1", issueID: "CARD-1", level: "card", text: "Build it", locationID: "resolvable/story",
            provenance: "machine-found", citationProvenance: "machine-found"
        ))
        var object = openingBoardObject("CARD-1")
        object.description = ManagedBlockFence.initialDescription(rendered: """
            ### Architectural Brief
            A concrete brief
            ### Definition of Done
            - [ ] <!-- yh:clause:c1 --> Build it (wrong/story)
            """)
        let card = try journal.card(id: ids.first)
        let readiness = ReadinessCheck(
            provenance: FakeProvenanceTester(), citations: FakeCitationResolver()
        )
        let verdict = try await readiness.inspectAtOpening(
            card: card, object: object, journal: journal,
            repositories: readinessRepositories, mainlines: ResolvedMainlines()
        )
        #expect(verdict == .notReady)
        #expect(try journal.clauses(issueID: "CARD-1").first?.locationID == "resolvable/story")
        #expect(try journal.currentCardLease(cardID: ids.first) == nil)
    }

    @Test("Opening inspection applies protected scope and edited transcription without reconciliation writes")
    // swiftlint:disable:next function_body_length
    func protectedScopeAndEditedTranscription() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let ids = try seedCards(journal, at: Date())
        try journal.recordArchitecturalBrief(cardID: ids.first, prose: "A concrete brief")
        try journal.insertClause(.init(
            cid: "c1", issueID: "CARD-1", level: "card", text: "Build it", locationID: "resolvable/story",
            provenance: "machine-found", citationProvenance: "machine-found"
        ))
        let original = TranscriptionBlock(
            repository: "backend", paths: ["source.swift"], mainlineCommit: "deadbeef", content: "old",
            contentHash: ManagedBlockFence.sha256("old"), authorSupplied: false
        )
        try journal.recordTranscriptionBlocks(cardID: ids.first, [original])
        let edited = TranscriptionBlock(
            repository: "backend", paths: ["source.swift"], mainlineCommit: "deadbeef", content: "edited",
            contentHash: ManagedBlockFence.sha256("edited"), authorSupplied: false
        )
        let clause = DoDClause(
            cid: "c1", text: "Build it", citation: "resolvable/story", citationProvenance: "machine-found"
        )
        func object(scope: [String], transcriptions: [TranscriptionBlock] = [edited]) -> BoardObject {
            var boardObject = openingBoardObject("CARD-1")
            let block = CardManagedBlock(
                kind: "card", repository: "backend", scope: scope, state: .todo, lanePosition: 1, laneLength: 1,
                brief: ArchitecturalBrief(prose: "A concrete brief", transcriptions: transcriptions),
                definitionOfDone: [clause], attempts: []
            )
            boardObject.description = ManagedBlockFence.initialDescription(rendered: block.render())
            return boardObject
        }
        let card = try journal.card(id: ids.first)
        let readiness = ReadinessCheck(
            provenance: FakeProvenanceTester(verdicts: ["backend": .stale(changedPaths: ["source.swift"])]),
            citations: FakeCitationResolver()
        )
        let repositories = ProjectRepositories(workingRepos: [
            Repo(name: "backend", path: "/nonexistent/backend", role: .backend, protectedPaths: ["secrets"])
        ])
        let protected = try await readiness.inspectAtOpening(
            card: card, object: object(scope: ["secrets/key"]), journal: journal,
            repositories: repositories, mainlines: ResolvedMainlines()
        )
        let editedVerdict = try await readiness.inspectAtOpening(
            card: card, object: object(scope: []), journal: journal,
            repositories: repositories, mainlines: ResolvedMainlines()
        )
        let mismatchedVerdict = try await readiness.inspectAtOpening(
            card: card, object: object(scope: [], transcriptions: []), journal: journal,
            repositories: repositories, mainlines: ResolvedMainlines()
        )
        #expect(protected == .notReady)
        #expect(editedVerdict == .ready)
        #expect(mismatchedVerdict == .unknown)
        #expect(try journal.transcriptionBlocks(cardID: ids.first)[0].content == "old")
        #expect(try journal.currentCardLease(cardID: ids.first) == nil)
    }

    @Test("Closing bound counters remain fixed when later Nights advance the Card")
    func closingBoundHistory() throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let run = RunID()
        _ = try journal.claimActLease(act: .land, runID: run, mode: .real)
        let ids = try seedCards(journal, at: Date())
        let firstStart = try #require(NightStart(rawValue: "2026-09-25"))
        let secondStart = try #require(NightStart(rawValue: "2026-09-26"))
        let first = try journal.openNight(
            nightStart: firstStart, mode: .real, act: .land, runID: run
        ).night
        try journal.write { db in
            try db.execute(
                sql: "UPDATE card SET unanswered_nights = 2, failed_adoptions = 1 WHERE id = ?",
                arguments: [ids.first]
            )
        }
        _ = try journal.closeNight(id: first.id, reason: .nightEnd, act: .land, runID: run)
        try journal.write { db in
            try db.execute(
                sql: "UPDATE card SET unanswered_nights = 5, failed_adoptions = 4 WHERE id = ?",
                arguments: [ids.first]
            )
        }
        let second = try journal.openNight(
            nightStart: secondStart, mode: .real, act: .land, runID: run
        ).night
        _ = try journal.closeNight(id: second.id, reason: .nightEnd, act: .land, runID: run)
        let old = try NightSummary.instrumentedRateLines(
            night: try #require(try journal.night(id: first.id)), journal: journal, bounds: .init()
        )
        let current = try NightSummary.instrumentedRateLines(
            night: try #require(try journal.night(id: second.id)), journal: journal, bounds: .init()
        )
        #expect(old.contains("`unanswered_nights_max`: 2 of 3 (highest Card count)."))
        #expect(old.contains("`failed_adoptions_max`: 1 of 2."))
        #expect(current.contains("`unanswered_nights_max`: 5 of 3 (highest Card count)."))
        #expect(current.contains("`failed_adoptions_max`: 4 of 2."))
    }
}

extension NightSummaryInstrumentedRatesTests {
    @Test("Two Nights retain hand-counted fractions, opening snapshots and the citation count")
    // swiftlint:disable:next function_body_length
    func twoNightRates() throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let run = RunID()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try journal.claimActLease(act: .author, runID: run, mode: .real, now: base)
        let day1 = try #require(NightStart(rawValue: "2026-09-23"))
        let first = try journal.openNight(
            nightStart: day1, mode: .real, act: .author, runID: run, now: base
        ).night
        try journal.recordOpeningReadyState(nightID: first.id, state: .zero)
        let ids = try seedCards(journal, at: base)
        try journal.append(.repoLaneStarted(repository: "backend", cards: 2), nightID: first.id, now: base)
        try journal.recordPullRequest(
            featureID: ids.feature, repository: "backend", url: "https://example.test/1",
            nightID: first.id, runID: run, now: base
        )
        try journal.append(
            .routeRetried(cardID: ids.first, issueID: "CARD-1", attemptID: 1,
                          route: try #require(Route(cli: "codex", model: "m1", effort: "medium")),
                          differentRoute: true), nightID: first.id, now: base
        )
        try journal.append(
            .featureReselected(depth: 1, afterRefusalOf: "FEAT-OLD", reselectionsMax: 2),
            nightID: first.id, now: base
        )
        try journal.append(
            .refusalOpened(feature: "FEAT-OLD", consecutiveRefusals: 2), nightID: first.id, now: base
        )
        for (cardID, issueID) in [(ids.first, "CARD-1"), (ids.second, "CARD-2")] {
            try journal.append(
                .cardStateTransitioned(cardID: cardID, issueID: issueID, from: .todo, to: .done,
                                       waitingReason: nil, blockReason: nil),
                nightID: first.id, now: base.addingTimeInterval(1)
            )
        }
        try journal.write { db in
            try db.execute(sql: "UPDATE card SET state = 'Done' WHERE id IN (?, ?)", arguments: [ids.first, ids.second])
        }
        _ = try journal.closeNight(
            id: first.id, reason: .nightEnd, act: .land, runID: run, now: base.addingTimeInterval(2)
        )

        let day2 = try #require(NightStart(rawValue: "2026-09-24"))
        let second = try journal.openNight(
            nightStart: day2, mode: .real, act: .author, runID: run, now: base.addingTimeInterval(3)
        ).night
        // Done and Blocked Cards remain. Without a read-only Readiness Check this start is unknown.
        try journal.append(
            .routeRetried(cardID: ids.first, issueID: "CARD-1", attemptID: 2,
                          route: try #require(Route(cli: "codex", model: "m1", effort: "medium")),
                          differentRoute: false), nightID: second.id, now: base.addingTimeInterval(3)
        )
        try journal.append(
            .humanCardComment(cardID: ids.second, commentID: "comment-1",
                              commentedAt: base.addingTimeInterval(4)),
            nightID: second.id, now: base.addingTimeInterval(4)
        )
        try journal.append(
            .featureSettled(cycleID: ids.cycle, featureIssueID: "FEAT-1",
                            acceptedCards: ["CARD-1", "CARD-2"], triagedNightID: first.id),
            nightID: second.id, now: base.addingTimeInterval(4)
        )
        // A comment after acceptance must not rewrite the already-observed proxy.
        try journal.append(
            .humanCardComment(cardID: ids.first, commentID: "comment-after-settle",
                              commentedAt: base.addingTimeInterval(5)),
            nightID: second.id, now: base.addingTimeInterval(5)
        )
        try journal.insertClause(.init(
            cid: "c1", issueID: "CARD-1", level: "card", text: "Do it", locationID: "spec#1",
            provenance: "Author-supplied", citationProvenance: "Author-supplied"
        ), now: base.addingTimeInterval(4))
        _ = try journal.closeNight(
            id: second.id, reason: .nightEnd, act: .land, runID: run, now: base.addingTimeInterval(5)
        )

        let closed = try #require(try journal.night(id: second.id))
        let lines = try NightSummary.instrumentedRateLines(
            night: closed, journal: journal, bounds: .init()
        )
        #expect(lines.contains { $0.contains("1/2 (50%)") && $0.contains("Upper bound") })
        #expect(lines.contains { $0.contains("pull request in every touched repository: 1/2 (50%)") })
        #expect(lines.contains {
            $0.contains("Nights started with zero Ready Cards: 1 of 2") &&
                $0.contains("0 nonzero, 1 unknown")
        })
        #expect(lines.contains { $0.contains("Retries on a different route: 1/2 (50%)") && $0.contains("no") })
        #expect(lines.contains("`author_supplied_citation_count`: 1 (at this Night's close)."))
        #expect(lines.contains("`reselections_max`: 0 of 2."))
        #expect(lines.contains("`consecutive_refusals_max`: 0 of 3."))
        #expect(lines.filter { $0.contains("_max`:") || $0.contains("attempts_per_card`:") }.count == 6)

        let firstLines = try NightSummary.instrumentedRateLines(
            night: try #require(try journal.night(id: first.id)), journal: journal, bounds: .init()
        )
        #expect(firstLines.contains("`reselections_max`: 1 of 2."))
        #expect(firstLines.contains("`consecutive_refusals_max`: 2 of 3."))
    }

    private func seedCards(_ journal: JournalStore, at date: Date) throws -> SeededIDs {
        try journal.write { db in
            let stamp = JournalStore.timestamp(date)
            try db.execute(
                sql: "INSERT INTO feature (issue_id, state, created_at) VALUES ('FEAT-1', 'open', ?)",
                arguments: [stamp]
            )
            let feature = db.lastInsertedRowID
            try db.execute(sql: "INSERT INTO cycle (feature_id, created_at) VALUES (?, ?)", arguments: [feature, stamp])
            let cycle = db.lastInsertedRowID
            try db.execute(
                sql: """
                INSERT INTO card (cycle_id, issue_id, repository, kind, authored_order, state, budget_epoch, created_at)
                VALUES (?, 'CARD-1', 'backend', 'card', 1, 'Todo', 0, ?)
                """, arguments: [cycle, stamp]
            )
            let first = db.lastInsertedRowID
            try db.execute(
                sql: """
                INSERT INTO card (cycle_id, issue_id, repository, kind, authored_order, state, budget_epoch, created_at)
                VALUES (?, 'CARD-2', 'backend', 'card', 2, 'Todo', 0, ?)
                """, arguments: [cycle, stamp]
            )
            let second = db.lastInsertedRowID
            // A Blocked Card remains on the board, but is not Ready at Night start.
            try db.execute(
                sql: """
                INSERT INTO card (cycle_id, issue_id, repository, kind, authored_order, state, budget_epoch, created_at)
                VALUES (?, 'CARD-3', 'backend', 'card', 3, 'Blocked', 0, ?)
                """, arguments: [cycle, stamp]
            )
            return SeededIDs(feature: feature, cycle: cycle, first: first, second: second)
        }
    }
}
