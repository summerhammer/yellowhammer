import Domain
import Foundation
import GRDB
import Testing

@testable import Engine
@testable import Journal

// routing/resolve-a-route-for-a-card (P7.6): the resolved Route is recorded on the Attempt and reaches
// the Card through the Managed Block; zero candidates move the Card to Blocked with Block Reason
// `hard failure` and record no phantom Attempt; a refused Override is a Readiness Check failure that
// writes nothing but its event. Rehearsal-assertable against the in-memory board.

private func route(_ cli: String, _ model: String, _ effort: String) -> Route {
    Route(cli: cli, model: model, effort: effort)!
}

private let claudeOpus = route("claude", "opus", "high")
private let codexMedium = route("codex", "gpt-5.4", "medium")

/// `insertFixtureCard` writes a Card of Kind `card` in repository `main`; this table routes it.
private let table = RoutingTable(entries: [
    RoutingEntry(kind: Kind("card")!, route: claudeOpus, fallbacks: [codexMedium])
])

private func resolver(probe: @escaping RouteResolver.ProbeEligibility = { _ in .offered }) -> RouteResolver {
    RouteResolver(table: table, probeEligibility: probe)
}

private func makeRoutingBoards() async throws -> NightCardTestBoards {
    let boards = try await makeBoards()
    await boards.provisioning.seed(state: "In Progress", team: teamID, category: .started)
    await boards.provisioning.seed(state: "Blocked", team: teamID, category: .unstarted)
    await boards.provisioning.seed(state: "Waiting on You", team: teamID, category: .unstarted)
    return boards
}

private func exclude(_ journal: JournalStore, cardID: Int64, epoch budgetEpoch: Int, _ route: Route) throws {
    try journal.write { db in
        try db.execute(
            sql: """
            INSERT INTO route_exclusion
            (card_id, budget_epoch, route_cli, route_model, route_effort, reason, excluded_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                cardID, budgetEpoch, route.cli, route.model, route.effort, "hard failure",
                JournalStore.timestamp(outboxEpoch)
            ]
        )
    }
}

/// Claims the Act-scoped lease for `runID`, so the Journal writes under it revalidate.
private func claimActLease(_ journal: JournalStore, runID: RunID) throws {
    let claim = try journal.claimActLease(act: .build, runID: runID, mode: .rehearsal, now: outboxEpoch)
    guard case .claimed = claim else {
        throw JournalError.actLeaseLost(runID: runID, holder: nil)
    }
}

private func attemptRowCount(_ journal: JournalStore, cardID: Int64) throws -> Int {
    try journal.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM attempt WHERE card_id = ?", arguments: [cardID]) ?? 0
    }
}

@Suite("Card routing at dispatch")
struct CardRoutingTests {
    @Test("A resolved Route is recorded on the Attempt and rendered onto the Card's Managed Block")
    func resolvedRouteIsRecordedAndReported() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeRoutingBoards()
        let scope = try await BoardStateScope.resolve(using: boards.provisioning)
        let runID = RunID()
        _ = await boards.writing.seed(issue: "issue-1", description: nil)
        let cardID = try insertFixtureCard(journal, issueID: "issue-1")
        let outbox = try outbox(journal, board: boards.writing, runID: runID)
        let projection = BoardStateProjection(journal: journal, outbox: outbox, scope: scope)
        let routing = CardRouting(
            resolver: resolver(), journal: journal, projection: projection, runID: runID, act: .build
        )

        let outcome = try await routing.route(card: try journal.card(id: cardID), repoRole: .backend, override: nil)

        guard case .attempt(let attempt, let resolved) = outcome else {
            Issue.record("expected an Attempt, got \(outcome)")
            return
        }
        #expect(attempt.route == claudeOpus)
        #expect(resolved.selectedBy == .entry)
        let history = try journal.attemptHistory(cardID: cardID)
        #expect(history.attempts.last?.route == claudeOpus)
        #expect(history.openAttempt?.id == attempt.id)

        let block = CardManagedBlock(
            kind: "card", repository: "main", state: .inProgress, lanePosition: 1, laneLength: 1,
            brief: ArchitecturalBrief(prose: "Brief", transcriptions: []), definitionOfDone: [],
            attempts: [AttemptAccount(ordinal: 1, record: attempt)]
        )
        #expect(block.render().contains("#### Attempt 1 — `claude/opus/high`"))
        #expect(try journal.card(id: cardID).state == .todo)
    }

    @Test("Zero candidates: Blocked with Block Reason hard failure, no phantom Attempt, the account in the Journal")
    func exhaustedBlocksWithoutAnAttempt() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeRoutingBoards()
        let scope = try await BoardStateScope.resolve(using: boards.provisioning)
        let runID = RunID()
        let issue = await boards.writing.seed(issue: "issue-1", description: nil)
        let cardID = try insertFixtureCard(journal, issueID: "issue-1")
        try exclude(journal, cardID: cardID, epoch: 0, claudeOpus)
        let outbox = try outbox(journal, board: boards.writing, runID: runID)
        _ = try journal.claimCardLease(cardID: cardID, runID: runID, now: outboxEpoch)
        let projection = BoardStateProjection(journal: journal, outbox: outbox, scope: scope)
        let codexFailed: RouteResolver.ProbeEligibility = { cli in
            cli == "codex" ? .excluded(reason: "unattended dispatch prompted") : .offered
        }
        let routing = CardRouting(
            resolver: resolver(probe: codexFailed), journal: journal, projection: projection, runID: runID, act: .build
        )

        let outcome = try await routing.route(card: try journal.card(id: cardID), repoRole: .backend, override: nil)

        guard case .blocked(let record, let exhaustion) = outcome else {
            Issue.record("expected blocked, got \(outcome)")
            return
        }
        #expect(record.state == .blocked)
        #expect(record.blockReason == BlockReason.hardFailure.rawValue)
        #expect(try journal.card(id: cardID).state == .blocked)
        #expect(try attemptRowCount(journal, cardID: cardID) == 0)
        #expect(exhaustion.skipped.map(\.route) == [claudeOpus, codexMedium])

        let events = try journal.events(ofType: .routeExhausted)
        #expect(events.count == 1)
        guard case .routeExhausted(let eventCardID, let issueID, let reason) = try #require(events.first?.event) else {
            Issue.record("expected routeExhausted")
            return
        }
        #expect(eventCardID == cardID)
        #expect(issueID == "issue-1")
        #expect(reason.hasPrefix("fallbacks exhausted"))
        #expect(reason.contains("unattended dispatch prompted"))

        let issueState = try #require(await boards.writing.issue(issue))
        #expect(issueState.workflowState == scope.states[.blocked])
        #expect(issueState.labels.contains(try #require(boards.ids["hard failure"])))
    }

    @Test("Without a Board the Blocked transition is written to the Journal alone")
    func exhaustedWithoutABoardWritesTheJournal() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        let cardID = try insertFixtureCard(journal, issueID: "issue-1")
        try claimActLease(journal, runID: runID)
        let neverProbed: RouteResolver.ProbeEligibility = { cli in .excluded(reason: "`\(cli)` has never been probed") }
        let routing = CardRouting(resolver: resolver(probe: neverProbed), journal: journal, runID: runID, act: .build)

        let outcome = try await routing.route(card: try journal.card(id: cardID), repoRole: .backend, override: nil)

        guard case .blocked(let record, _) = outcome else {
            Issue.record("expected blocked, got \(outcome)")
            return
        }
        #expect(record.state == .blocked)
        #expect(record.blockReason == BlockReason.hardFailure.rawValue)
        #expect(try attemptRowCount(journal, cardID: cardID) == 0)
        #expect(try journal.cardsWithUnpostedState().map(\.id) == [cardID])
    }

    @Test("A refused Override is a Readiness Check failure: no Attempt, the Card untouched, the refusal recorded")
    func refusedOverrideWritesOnlyItsEvent() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeRoutingBoards()
        let scope = try await BoardStateScope.resolve(using: boards.provisioning)
        let runID = RunID()
        _ = await boards.writing.seed(issue: "issue-1", description: nil)
        let cardID = try insertFixtureCard(journal, issueID: "issue-1")
        let outbox = try outbox(journal, board: boards.writing, runID: runID)
        let projection = BoardStateProjection(journal: journal, outbox: outbox, scope: scope)
        let codexFailed: RouteResolver.ProbeEligibility = { cli in
            cli == "codex" ? .excluded(reason: "process containment: orphan") : .offered
        }
        let routing = CardRouting(
            resolver: resolver(probe: codexFailed), journal: journal, projection: projection, runID: runID, act: .build
        )
        let before = try journal.card(id: cardID)

        let outcome = try await routing.route(
            card: before, repoRole: .backend, override: Override(label: "codex/gpt-5.4/medium")
        )

        guard case .readinessFailure(let record, let refusal) = outcome else {
            Issue.record("expected readinessFailure, got \(outcome)")
            return
        }
        #expect(record == before)
        #expect(try journal.card(id: cardID) == before)
        #expect(try attemptRowCount(journal, cardID: cardID) == 0)
        guard case .probeFailed(_, let cli, _) = refusal else {
            Issue.record("expected probeFailed, got \(refusal)")
            return
        }
        #expect(cli == "codex")
        let events = try journal.events(ofType: .overrideRefused)
        #expect(events.count == 1)
        let expected = JournalEvent.overrideRefused(cardID: cardID, issueID: "issue-1", reason: refusal.description)
        #expect(events.first?.event == expected)
        #expect(await boards.writing.updateCalls == 0)
    }

    @Test("An Override beats the exclusion set the Journal holds: the pinned excluded route is attempted")
    func overrideBeatsTheJournalsExclusion() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        let cardID = try insertFixtureCard(journal, issueID: "issue-1")
        try exclude(journal, cardID: cardID, epoch: 0, claudeOpus)
        try claimActLease(journal, runID: runID)
        let routing = CardRouting(resolver: resolver(), journal: journal, runID: runID, act: .build)

        let outcome = try await routing.route(
            card: try journal.card(id: cardID), repoRole: .backend, override: Override(label: "claude/opus/high")
        )

        guard case .attempt(let attempt, let resolved) = outcome else {
            Issue.record("expected an Attempt, got \(outcome)")
            return
        }
        #expect(attempt.route == claudeOpus)
        #expect(resolved.selectedBy == .override)
    }

    @Test("The exclusion set is the Card's current budget epoch's, not its whole history")
    func exclusionIsScopedToTheCurrentEpoch() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        let cardID = try insertFixtureCard(journal, issueID: "issue-1")
        // The primary route was excluded in epoch 0; the Card has since moved to epoch 1.
        try exclude(journal, cardID: cardID, epoch: 0, claudeOpus)
        try journal.write { db in
            try db.execute(sql: "UPDATE card SET budget_epoch = 1 WHERE id = ?", arguments: [cardID])
        }
        try claimActLease(journal, runID: runID)
        let routing = CardRouting(resolver: resolver(), journal: journal, runID: runID, act: .build)

        let outcome = try await routing.route(card: try journal.card(id: cardID), repoRole: .backend, override: nil)

        guard case .attempt(let attempt, let resolved) = outcome else {
            Issue.record("expected an Attempt, got \(outcome)")
            return
        }
        #expect(attempt.route == claudeOpus)
        #expect(attempt.budgetEpoch == 1)
        #expect(resolved.skipped.isEmpty)
    }
}

// Route exclusion on retry (routing/exclude-tried-routes-on-retry, P7.7) is covered in
// CardRoutingRetryTests.swift, which extends this suite — split out to keep this file under the
// length limit.
