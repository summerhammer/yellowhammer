import Domain
import Foundation
import GRDB
import Testing

@testable import Journal

// risks OQ104, OQ107: the No-Pushed-Branch Outcome's record and the two reads over it. N
// (`pushedRepositories`) is `touchedRepositories` minus the repositories with a recorded outcome that no
// later push superseded.

private struct JournalFixture: ~Copyable {
    let directory: URL
    let projectID: ProjectID

    init(project: String = "fixture") throws {
        directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-journal-\(UUID().uuidString)", directoryHint: .isDirectory)
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

/// A Feature touching `backend` and `mobile`.
private func insertTouchingFeature(_ journal: JournalStore, issueID: String) throws -> Int64 {
    try journal.write { database in
        try database.execute(
            sql: "INSERT INTO feature (issue_id, state, created_at) VALUES (?, ?, ?)",
            arguments: [issueID, "selected", JournalStore.timestamp(epoch)]
        )
        let featureID = database.lastInsertedRowID
        try JournalStore.insertFeatureRepositories(database, featureID: featureID, repositories: ["backend", "mobile"])
        return featureID
    }
}

private func recordPushedWorktree(_ journal: JournalStore, featureID: Int64, repository: String) throws {
    try journal.write { database in
        try database.execute(
            sql: """
            INSERT INTO worktree (feature_id, repository, worktree_id, path, created_at, pushed_commit)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                featureID, repository, "wt-\(repository)", "/tmp/\(repository)", JournalStore.timestamp(epoch), "abc123"
            ]
        )
    }
}

@Suite("No-Pushed-Branch Outcome store")
struct NoPushedBranchStoreTests {
    @Test("noPushedBranchOutcome round-trips through the event log")
    func eventRoundTrips() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let event = JournalEvent.noPushedBranchOutcome(cycleID: 7, featureIssueID: "FEAT-1", repository: "mobile")

        try journal.append(event, act: .land, now: epoch)

        let records = try journal.events(ofType: .noPushedBranchOutcome)
        #expect(records.map(\.event) == [event])
        #expect(JournalEventType.noPushedBranchOutcome.rawValue == "NoPushedBranchOutcome")
    }

    @Test("With no recorded outcome N is every touched repository")
    func noOutcomeMeansNIsTouched() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let featureID = try insertTouchingFeature(journal, issueID: "FEAT-1")

        #expect(try journal.noPushedBranchRepositories(featureID: featureID).isEmpty)
        #expect(try journal.pushedRepositories(featureID: featureID) == ["backend", "mobile"])
    }

    @Test("A recorded outcome takes the repository out of N and leaves touchedRepositories unchanged")
    func outcomeLeavesN() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let featureID = try insertTouchingFeature(journal, issueID: "FEAT-1")

        try journal.append(.noPushedBranchOutcome(cycleID: 1, featureIssueID: "FEAT-1", repository: "mobile"))

        #expect(try journal.noPushedBranchRepositories(featureID: featureID) == ["mobile"])
        #expect(try journal.pushedRepositories(featureID: featureID) == ["backend"])
        #expect(try journal.touchedRepositories(featureID: featureID) == ["backend", "mobile"])
    }

    @Test("Every touched repository with the outcome leaves N empty")
    func everyRepositoryWithOutcomeIsEmptyN() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let featureID = try insertTouchingFeature(journal, issueID: "FEAT-1")

        for repository in ["backend", "mobile"] {
            try journal.append(.noPushedBranchOutcome(cycleID: 1, featureIssueID: "FEAT-1", repository: repository))
        }

        #expect(try journal.pushedRepositories(featureID: featureID).isEmpty)
        #expect(try journal.touchedRepositories(featureID: featureID) == ["backend", "mobile"])
    }

    @Test("A later recorded push supersedes the outcome: the repository is back in N")
    func laterPushSupersedes() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let featureID = try insertTouchingFeature(journal, issueID: "FEAT-1")

        try journal.append(.noPushedBranchOutcome(cycleID: 1, featureIssueID: "FEAT-1", repository: "mobile"))
        try recordPushedWorktree(journal, featureID: featureID, repository: "mobile")

        #expect(try journal.noPushedBranchRepositories(featureID: featureID).isEmpty)
        #expect(try journal.pushedRepositories(featureID: featureID) == ["backend", "mobile"])
    }

    @Test("An outcome event naming another Feature does not count")
    func otherFeatureOutcomeDoesNotCount() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let featureID = try insertTouchingFeature(journal, issueID: "FEAT-1")
        _ = try insertTouchingFeature(journal, issueID: "FEAT-2")

        try journal.append(.noPushedBranchOutcome(cycleID: 2, featureIssueID: "FEAT-2", repository: "mobile"))

        #expect(try journal.noPushedBranchRepositories(featureID: featureID).isEmpty)
        #expect(try journal.pushedRepositories(featureID: featureID) == ["backend", "mobile"])
    }
}
