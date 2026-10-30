import Domain
import Foundation
import Testing

@testable import Journal

@Test("pullRequestReadFailed round-trips its repository and each of the five reasons (OQ190 item 28)")
func pullRequestReadFailedRoundTrips() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(component: "yh-journal-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let journal = try JournalStore.open(
        configurationDirectory: directory, projectID: try #require(ProjectID(rawValue: "fixture"))
    )

    for reason in PullRequestReadFailure.Reason.allCases {
        try journal.append(.pullRequestReadFailed(repository: "backend", reason: reason), act: .author, runID: RunID())
    }

    let records = try journal.events(ofType: .pullRequestReadFailed)
    #expect(records.map(\.type.rawValue) == Array(repeating: "PullRequestReadFailed", count: 5))
    #expect(records.map(\.event) == PullRequestReadFailure.Reason.allCases.map {
        .pullRequestReadFailed(repository: "backend", reason: $0)
    })
    #expect(PullRequestReadFailure.Reason.allCases.map(\.rawValue) == [
        "unreachable", "credential_refused", "no_access", "rate_limited", "unreadable_answer"
    ])
}

@Test("multiplePullRequestsObserved round-trips its repository, Feature Branch and pull request numbers (#714)")
func multiplePullRequestsObservedRoundTrips() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(component: "yh-journal-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let journal = try JournalStore.open(
        configurationDirectory: directory, projectID: try #require(ProjectID(rawValue: "fixture"))
    )
    let event = JournalEvent.multiplePullRequestsObserved(
        repository: "backend", branch: "yh/feat-1", numbers: [4, 7, 12]
    )

    try journal.append(event, act: .author, runID: RunID())

    let records = try journal.events(ofType: .multiplePullRequestsObserved)
    #expect(records.map(\.type.rawValue) == ["MultiplePullRequestsObserved"])
    #expect(records.map(\.event) == [event])
}
