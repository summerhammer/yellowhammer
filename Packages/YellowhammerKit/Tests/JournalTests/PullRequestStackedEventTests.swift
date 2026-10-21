import Domain
import Foundation
@testable import Journal
import Testing

// roadmap P23.4 (spec: landing/open-one-pull-request-per-repository `#stack-notice`): the land Act records the
// stack base of a stacked pull request as a Journal event, so the Night Summary can name the predecessor's pull
// request without a schema change.

private struct StackedEventFixture: ~Copyable {
    let directory: URL
    let projectID: ProjectID

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-stacked-event-\(UUID().uuidString)", directoryHint: .isDirectory)
        projectID = try #require(ProjectID(rawValue: "fixture"))
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func open() throws -> JournalStore {
        try JournalStore.open(configurationDirectory: directory, projectID: projectID)
    }
}

@Suite("Journal: pullRequestStacked event (P23.4)")
struct PullRequestStackedEventTests {
    @Test("pullRequestStacked round-trips through the event log, with and without the predecessor's URL")
    func roundTrips() throws {
        let fixture = try StackedEventFixture()
        let journal = try fixture.open()
        let withURL = JournalEvent.pullRequestStacked(
            featureIssueID: "FEAT-2", repository: "repo-a", predecessorFeatureIssueID: "FEAT-1",
            predecessorBranch: "yh-proj-f1", predecessorPullRequestURL: "https://github.com/o/repo-a/pull/7"
        )
        let withoutURL = JournalEvent.pullRequestStacked(
            featureIssueID: "FEAT-2", repository: "repo-b", predecessorFeatureIssueID: "FEAT-1",
            predecessorBranch: "yh-proj-f1", predecessorPullRequestURL: nil
        )
        try journal.append(withURL)
        try journal.append(withoutURL)

        let records = try journal.events(ofType: .pullRequestStacked)
        #expect(records.map(\.event) == [withURL, withoutURL])
        #expect(withoutURL.payload?["predecessor_pull_request_url"] == nil)
        #expect(JournalEventType.pullRequestStacked.rawValue == "PullRequestStacked")
        #expect(withURL.type == .pullRequestStacked)
    }
}
