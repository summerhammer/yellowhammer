import Domain
import Foundation
import GRDB
import Testing

@testable import Journal

private struct JournalFixture: ~Copyable {
    let directory: URL
    let projectID: ProjectID

    init(project: String = "fixture") throws {
        directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-delta-sync-\(UUID().uuidString)", directoryHint: .isDirectory)
        projectID = try #require(ProjectID(rawValue: project))
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func open() throws -> JournalStore {
        try JournalStore.open(configurationDirectory: directory, projectID: projectID)
    }
}

private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

// MARK: - Sync Point Tests

@Test("Fresh Journal has no sync point")
func freshJournalHasNoSyncPoint() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()

    let syncPoint = try journal.boardSyncPoint()
    #expect(syncPoint == nil)
}

private func record(
    issues: Date? = nil, comments: Date? = nil, observations: [BoardIssueObservation] = [],
    commentIDs: [String] = [], leavesBuildPending: Bool = false, clearsBuildPending: Bool = false,
    forgetsBefore: Date? = nil
) -> BoardReadRecord {
    BoardReadRecord(
        issuesSynced: issues, commentsSynced: comments, issues: observations,
        comments: commentIDs.map { BoardCommentObservation(commentID: $0, createdAt: epoch) },
        leavesBuildPending: leavesBuildPending, clearsBuildPending: clearsBuildPending,
        forgetsBefore: forgetsBefore
    )
}

@Test("recordBoardRead stores and returns a sync point with one cursor per root")
func recordBoardReadStoresPerRootCursors() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let runID = RunID()
    _ = try journal.claimActLease(act: .author, runID: runID, mode: .real, now: epoch)

    let issues = Date(timeIntervalSince1970: 1_789_000_000)
    let comments = Date(timeIntervalSince1970: 1_789_000_500)
    let recorded = try journal.recordBoardRead(
        record(issues: issues, comments: comments), runID: runID, now: epoch
    )

    #expect(recorded.issuesSynced == issues)
    #expect(recorded.commentsSynced == comments)
    #expect(recorded.lastSync == comments)
    #expect(recorded.readAt == epoch)
    #expect(recorded.runID == runID)
    #expect(try journal.boardSyncPoint() == recorded)
}

@Test("Fractional timestamps in the cursors round-trip exactly")
func fractionalTimestampRoundTrips() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let runID = RunID()
    _ = try journal.claimActLease(act: .author, runID: runID, mode: .real, now: epoch)

    let issues = Date(timeIntervalSince1970: 1_789_000_000.25)
    _ = try journal.recordBoardRead(record(issues: issues), runID: runID, now: epoch)

    let fetched = try journal.boardSyncPoint()
    #expect(fetched?.issuesSynced == issues)
    #expect(fetched?.commentsSynced == nil)
}

@Test("A cursor moves forward only, and a root left out keeps its cursor")
func cursorsNeverMoveBackwards() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let runID = RunID()
    _ = try journal.claimActLease(act: .author, runID: runID, mode: .real, now: epoch)

    let early = Date(timeIntervalSince1970: 1_789_000_000)
    let late = Date(timeIntervalSince1970: 1_790_000_000)
    _ = try journal.recordBoardRead(record(issues: late, comments: late), runID: runID, now: epoch)
    let second = try journal.recordBoardRead(
        record(issues: early), runID: runID, now: epoch.addingTimeInterval(60)
    )

    #expect(second.issuesSynced == late)
    #expect(second.commentsSynced == late)
    #expect(try journal.boardSyncPoint()?.readAt == epoch.addingTimeInterval(60))
}

@Test("recordBoardRead without Act lease throws actLeaseLost and stores nothing")
func recordBoardReadWithoutLease() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let runID = RunID()

    let revision = BoardIssueObservation(issueID: "i-1", updatedAt: epoch, payload: "{}")
    #expect(throws: JournalError.actLeaseLost(runID: runID, holder: nil)) {
        try journal.recordBoardRead(
            record(issues: epoch, observations: [revision], commentIDs: ["c-1"]), runID: runID, now: epoch
        )
    }
    #expect(try journal.boardSyncPoint() == nil)
    #expect(try journal.observedIssueRevisions(["i-1"]).isEmpty)
    #expect(try journal.observedCommentIDs(["c-1"]).isEmpty)
}

// MARK: - Observations

@Test("Observed issue revisions and comment ids are stored with the cursors, and read back by id")
func observationsAreStoredWithTheCursors() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let runID = RunID()
    _ = try journal.claimActLease(act: .build, runID: runID, mode: .real, now: epoch)

    let first = Date(timeIntervalSince1970: 1_789_000_000)
    let revisions = [
        BoardIssueObservation(issueID: "i-1", updatedAt: first, payload: "{}"),
        BoardIssueObservation(issueID: "i-2", updatedAt: first.addingTimeInterval(5), payload: "{}")
    ]
    _ = try journal.recordBoardRead(
        record(issues: first, observations: revisions, commentIDs: ["c-1", "c-2"]), runID: runID, now: epoch
    )

    #expect(try journal.observedIssueRevisions(["i-1", "i-2", "i-3"]) == [
        "i-1": first, "i-2": first.addingTimeInterval(5)
    ])
    #expect(try journal.observedCommentIDs(["c-1", "c-3"]) == ["c-1"])
}

@Test("A newer revision of an issue replaces the stored one")
func newerRevisionReplaces() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let runID = RunID()
    _ = try journal.claimActLease(act: .build, runID: runID, mode: .real, now: epoch)

    let first = Date(timeIntervalSince1970: 1_789_000_000)
    _ = try journal.recordBoardRead(
        record(observations: [BoardIssueObservation(issueID: "i-1", updatedAt: first, payload: "{}")]),
        runID: runID, now: epoch
    )
    _ = try journal.recordBoardRead(
        record(observations: [BoardIssueObservation(
            issueID: "i-1", updatedAt: first.addingTimeInterval(9), payload: "{}"
        )]),
        runID: runID, now: epoch
    )

    #expect(try journal.observedIssueRevisions(["i-1"]) == ["i-1": first.addingTimeInterval(9)])
}

@Test("A revision left pending for the build Act stays until a build read clears it")
func pendingObservationsClearOnBuildRead() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let runID = RunID()
    _ = try journal.claimActLease(act: .author, runID: runID, mode: .real, now: epoch)

    let revision = BoardIssueObservation(issueID: "i-1", updatedAt: epoch, payload: "{\"a\":1}")
    _ = try journal.recordBoardRead(
        record(observations: [revision], leavesBuildPending: true), runID: runID, now: epoch
    )
    #expect(try journal.buildPendingObservations().map(\.issueID) == ["i-1"])
    #expect(try journal.buildPendingObservations().first?.payload == "{\"a\":1}")

    _ = try journal.recordBoardRead(record(clearsBuildPending: true), runID: runID, now: epoch)
    #expect(try journal.buildPendingObservations().isEmpty)
    // Cleared, not forgotten: the revision still deduplicates a re-read.
    #expect(try journal.observedIssueRevisions(["i-1"]) == ["i-1": epoch])
}

@Test("Observations older than the cutoff are forgotten, pending ones are kept")
func oldObservationsAreForgotten() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let runID = RunID()
    _ = try journal.claimActLease(act: .author, runID: runID, mode: .real, now: epoch)

    let old = Date(timeIntervalSince1970: 1_700_000_000)
    _ = try journal.recordBoardRead(
        record(observations: [BoardIssueObservation(issueID: "i-old", updatedAt: old, payload: "{}")]),
        runID: runID, now: epoch
    )
    _ = try journal.recordBoardRead(
        record(
            observations: [BoardIssueObservation(issueID: "i-pending", updatedAt: old, payload: "{}")],
            leavesBuildPending: true
        ),
        runID: runID, now: epoch
    )
    _ = try journal.recordBoardRead(record(forgetsBefore: epoch), runID: runID, now: epoch)

    #expect(try journal.observedIssueRevisions(["i-old", "i-pending"]) == ["i-pending": old])
}

// MARK: - Card Read Tests

@Test("cards() returns all fixture Cards ordered by id")
func cardsReturnsAllOrdered() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()

    let card1ID = try insertFixtureCard(journal, issueID: "CARD-1")
    let card2ID = try insertFixtureCard(journal, issueID: "CARD-2")

    let cards = try journal.cards()
    #expect(cards.count == 2)
    #expect(cards[0].id == card1ID)
    #expect(cards[1].id == card2ID)
    #expect(cards[0].issueID == "CARD-1")
    #expect(cards[1].issueID == "CARD-2")
}

@Test("card(issueID:) reads a Card by issue ID with all fields")
func cardByIssueID() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()

    let cardID = try insertFixtureCard(journal, issueID: "CARD-123")

    let card = try journal.card(issueID: "CARD-123")
    #expect(card != nil)
    #expect(card?.id == cardID)
    #expect(card?.issueID == "CARD-123")
    #expect(card?.state == .todo)
    #expect(card?.shelvedFromState == nil)
    #expect(card?.waitingReason == nil)
}

@Test("card(id:) throws cardUnknown when Card id does not exist")
func cardByIDThrowsUnknown() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()

    #expect(throws: JournalError.cardUnknown(cardID: 9999)) {
        _ = try journal.card(id: 9999)
    }
}

// MARK: - Card Shelving Tests

@Test("markCardShelved on a Blocked Card yields shelved state with previousState")
func markCardShelvedSetsState() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let runID = RunID()

    let cardID = try insertFixtureCardWithState(
        journal, issueID: "CARD-1", state: .blocked
    )

    _ = try journal.claimActLease(
        act: .author, runID: runID, mode: .real, now: epoch
    )

    let result = try journal.markCardShelved(
        cardID: cardID, runID: runID, act: .author, nightID: nil, now: epoch
    )

    #expect(result.state == .shelved)
    #expect(result.shelvedFromState == .blocked)

    let events = try journal.events(ofType: .cardShelved)
    #expect(events.count == 1)
    guard case .cardShelved(let eCardID, let issueID, let prevState) = events[0].event else {
        Issue.record("Event is not cardShelved")
        return
    }
    #expect(eCardID == cardID)
    #expect(issueID == "CARD-1")
    #expect(prevState == .blocked)
}

@Test("markCardShelved twice throws cardAlreadyShelved")
func markCardShelvedTwiceThrows() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let runID = RunID()

    let cardID = try insertFixtureCardWithState(
        journal, issueID: "CARD-1", state: .inProgress
    )
    _ = try journal.claimActLease(act: .author, runID: runID, mode: .real, now: epoch)

    _ = try journal.markCardShelved(
        cardID: cardID, runID: runID, act: .author, nightID: nil, now: epoch
    )

    #expect(throws: JournalError.cardAlreadyShelved(cardID: cardID)) {
        try journal.markCardShelved(
            cardID: cardID,
            runID: runID,
            act: .author,
            nightID: nil,
            now: epoch.addingTimeInterval(1)
        )
    }
}

@Test("restoreShelvedCard yields previous state with cleared column")
func restoreShelvedCardRestoresState() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let runID = RunID()

    let cardID = try insertFixtureCardWithState(
        journal, issueID: "CARD-1", state: .blocked
    )
    _ = try journal.claimActLease(
        act: .author, runID: runID, mode: .real, now: epoch
    )

    _ = try journal.markCardShelved(
        cardID: cardID, runID: runID, act: .author, nightID: nil, now: epoch
    )

    let restored = try journal.restoreShelvedCard(
        cardID: cardID, runID: runID, act: .author, nightID: nil,
        now: epoch.addingTimeInterval(1)
    )

    #expect(restored.state == .blocked)
    #expect(restored.shelvedFromState == nil)

    let events = try journal.events(ofType: .cardReopened)
    #expect(events.count == 1)
    guard case .cardReopened(let eCardID, let issueID, let restoredState) = events[0].event else {
        Issue.record("Event is not cardReopened")
        return
    }
    #expect(eCardID == cardID)
    #expect(issueID == "CARD-1")
    #expect(restoredState == .blocked)
}

@Test("restoreShelvedCard on non-shelved Card throws cardNotShelved")
func restoreNonShelvedThrows() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let runID = RunID()

    let cardID = try insertFixtureCardWithState(
        journal, issueID: "CARD-1", state: .inProgress
    )
    _ = try journal.claimActLease(act: .author, runID: runID, mode: .real, now: epoch)

    #expect(throws: JournalError.cardNotShelved(cardID: cardID)) {
        try journal.restoreShelvedCard(
            cardID: cardID, runID: runID, act: .author, nightID: nil, now: epoch
        )
    }
}

@Test("markCardShelved without Act lease throws actLeaseLost")
func markCardShelvedWithoutLease() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let runID = RunID()

    let cardID = try insertFixtureCard(journal, issueID: "CARD-1")

    #expect(throws: JournalError.actLeaseLost(runID: runID, holder: nil)) {
        try journal.markCardShelved(
            cardID: cardID, runID: runID, act: .author, nightID: nil, now: epoch
        )
    }
}

// MARK: - Helpers

private func insertFixtureCard(_ journal: JournalStore, issueID: String) throws -> Int64 {
    try insertFixtureCardWithState(journal, issueID: issueID, state: .todo)
}

private func insertFixtureCardWithState(
    _ journal: JournalStore,
    issueID: String,
    state: CardState
) throws -> Int64 {
    try journal.write { db in
        try db.execute(
            sql: "INSERT INTO feature (issue_id, state, created_at) VALUES (?, ?, ?)",
            arguments: ["feature-of-\(issueID)", "selected", JournalStore.timestamp(epoch)]
        )
        let featureID = db.lastInsertedRowID
        try db.execute(
            sql: "INSERT INTO cycle (feature_id, created_at) VALUES (?, ?)",
            arguments: [featureID, JournalStore.timestamp(epoch)]
        )
        let cycleID = db.lastInsertedRowID
        try db.execute(
            sql: """
            INSERT INTO card (cycle_id, issue_id, repository, kind, authored_order, state, \
            budget_epoch, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                cycleID, issueID, "main", "card", 1, state.rawValue, 0, JournalStore.timestamp(epoch)
            ]
        )
        return db.lastInsertedRowID
    }
}
