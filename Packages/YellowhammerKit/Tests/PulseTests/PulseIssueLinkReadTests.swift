import Domain
import Foundation
import Testing

@testable import Journal
@testable import Pulse

// issue #230: the Pulse's ways out to Linear and GitHub are the URLs the Journal recorded. The read
// fills a link only from a recorded identifier and an http(s) URL, and opens nothing it composed.

/// A throwaway configuration directory holding one Project's Journal. Removed on deinit, so a test
/// creates it in its own body: a helper returning it would delete the Journal under the caller.
private struct JournalFixture: ~Copyable {
    let directory: URL
    let projectID: ProjectID

    init(project: String = "fixture") throws {
        directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-pulse-links-\(UUID().uuidString)", directoryHint: .isDirectory)
        projectID = try #require(ProjectID(rawValue: project))
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func open() throws -> JournalStore {
        try JournalStore.open(configurationDirectory: directory, projectID: projectID)
    }
}

private func link(_ identifier: String, _ url: String) throws -> LinearIssueLink {
    LinearIssueLink(identifier: identifier, url: try #require(URL(string: url)))
}

@Test("Recorded links reach the Needs you card, the running Attempt, the lane card, the Feature and the Night")
func recordedLinksAreCarried() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let feature = try insertFeature(journal, issueID: "F-1")
    let blocked = try insertCard(
        journal, cycleID: feature.cycleID, issueID: "C-1", state: .blocked, blockReason: .hardFailure, order: 1
    )
    try insertCard(journal, cycleID: feature.cycleID, issueID: "C-2", state: .todo, order: 2)
    let run = RunID()
    _ = try journal.claimActLease(act: .build, runID: run, mode: .real, now: epoch)
    _ = try journal.recordAttempt(cardID: blocked, route: route(), runID: run, now: epoch)
    let opening = try journal.openNight(nightStart: nightStart, mode: .real, act: .build, runID: run, now: epoch)
    _ = try journal.recordNightCard(id: opening.night.id, issueID: "N-1", act: .build, runID: run, now: epoch)
    for (issueID, key) in [("C-1", "YH-1"), ("F-1", "YH-9"), ("N-1", "YH-100")] {
        _ = try journal.recordIssueLink(
            issueID: issueID, key: key, url: "https://linear.app/x/issue/\(key)", runID: run, now: epoch
        )
    }

    let snapshot = try PulseSnapshot.read(from: journal, status: .idle)

    #expect(snapshot.needsYou.cards.first?.link == (try link("YH-1", "https://linear.app/x/issue/YH-1")))
    #expect(snapshot.now.attempts.first?.cardLink == (try link("YH-1", "https://linear.app/x/issue/YH-1")))
    let lane = try #require(snapshot.feature?.lanes.first)
    #expect(lane.cards.first { $0.id == "C-1" }?.link == (try link("YH-1", "https://linear.app/x/issue/YH-1")))
    #expect(lane.cards.first { $0.id == "C-2" }?.link == nil)
    #expect(snapshot.feature?.link == (try link("YH-9", "https://linear.app/x/issue/YH-9")))
    #expect(snapshot.night?.nightCard == (try link("YH-100", "https://linear.app/x/issue/YH-100")))
}

@Test("Links are nil when nothing was recorded")
func absentLinksAreNil() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let feature = try insertFeature(journal, issueID: "F-1")
    try insertCard(journal, cycleID: feature.cycleID, issueID: "C-1", state: .waitingOnYou, order: 1)
    let run = RunID()
    _ = try journal.claimActLease(act: .build, runID: run, mode: .real, now: epoch)
    _ = try journal.openNight(nightStart: nightStart, mode: .real, act: .build, runID: run, now: epoch)

    let snapshot = try PulseSnapshot.read(from: journal, status: .idle)

    #expect(snapshot.needsYou.cards.first?.link == nil)
    #expect(snapshot.feature?.link == nil)
    #expect(snapshot.feature?.lanes.first?.cards.first?.link == nil)
    #expect(snapshot.night?.nightCard == nil)
}

@Test("A recorded URL that is not http or https gives no link and no pull request chip")
func nonWebURLsAreRefused() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let feature = try insertFeature(journal, issueID: "F-1")
    try insertCard(journal, cycleID: feature.cycleID, issueID: "C-1", state: .blocked, order: 1)
    let run = RunID()
    _ = try journal.claimActLease(act: .land, runID: run, mode: .real, now: epoch)
    let opening = try journal.openNight(nightStart: nightStart, mode: .real, act: .land, runID: run, now: epoch)
    _ = try journal.recordIssueLink(issueID: "C-1", key: "YH-1", url: "file:///x", runID: run, now: epoch)
    _ = try journal.recordIssueLink(issueID: "F-1", key: "YH-9", url: "", runID: run, now: epoch)
    _ = try journal.recordPullRequest(
        featureID: feature.featureID, repository: "main", url: "file:///x/pull/7",
        nightID: opening.night.id, runID: run, now: epoch
    )

    let snapshot = try PulseSnapshot.read(from: journal, status: .idle)

    #expect(snapshot.needsYou.cards.first?.link == nil)
    #expect(snapshot.feature?.link == nil)
    #expect(snapshot.feature?.lanes.first?.pullRequest == nil)
}

@Test("A Card's detail carries the link recorded for it")
func cardDetailCarriesLink() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let feature = try insertFeature(journal, issueID: "F-1")
    try insertCard(journal, cycleID: feature.cycleID, issueID: "C-1", order: 1)
    try insertCard(journal, cycleID: feature.cycleID, issueID: "C-2", order: 2)
    let run = RunID()
    _ = try journal.claimActLease(act: .build, runID: run, mode: .real, now: epoch)
    _ = try journal.recordIssueLink(
        issueID: "C-1", key: "YH-1", url: "https://linear.app/x/issue/YH-1", runID: run, now: epoch
    )

    let expected = try link("YH-1", "https://linear.app/x/issue/YH-1")
    #expect(try CardDetail.read(from: journal, issueID: "C-1")?.link == expected)
    #expect(try CardDetail.read(from: journal, issueID: "C-2")?.link == nil)
}
