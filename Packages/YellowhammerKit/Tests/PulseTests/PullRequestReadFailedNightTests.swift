import Domain
import Foundation
import Testing

@testable import Journal
@testable import Pulse

// feature-authoring/select-the-next-feature `#pull-request-read`: a failed read is not a failure. The Night's
// account words it, but no Act failed, the Night counts no problem and no Failure Notice is raised.

private struct ReadFailedFixture: ~Copyable {
    let directory = FileManager.default.temporaryDirectory.appending(component: "yh-pulse-pr-read-\(UUID())")

    deinit { try? FileManager.default.removeItem(at: directory) }

    func open() throws -> JournalStore {
        try JournalStore.open(configurationDirectory: directory, projectID: #require(ProjectID(rawValue: "fixture")))
    }
}

@Suite("A failed pull request read in a Night")
struct PullRequestReadFailedNightTests {
    @Test("A Night whose only notable event is a failed pull request read has no failed Act and no problem")
    func readFailureIsNoProblem() throws {
        let fixture = ReadFailedFixture()
        let journal = try fixture.open()
        let run = RunID()
        _ = try journal.claimActLease(act: .author, runID: run, mode: .real, now: epoch)
        let night = try journal.openNight(nightStart: nightStart, mode: .real, act: .author, runID: run, now: epoch)
            .night
        try journal.append(.actStarted, act: .author, runID: run, nightID: night.id, now: epoch.addingTimeInterval(1))
        try journal.append(
            .pullRequestReadFailed(repository: "backend", reason: .rateLimited),
            act: .author, runID: run, nightID: night.id, now: epoch.addingTimeInterval(2)
        )
        try journal.append(.actEnded, act: .author, runID: run, nightID: night.id, now: epoch.addingTimeInterval(3))

        let account = try #require(try NightAccount.read(from: journal, nightID: night.id))
        let entries = account.runs.flatMap(\.entries)
        let readFailure = try #require(entries.first { $0.headline == "Could not read the pull request in backend" })
        #expect(!readFailure.isProblem)
        #expect(entries.allSatisfy { $0.failedAct == nil })
        #expect(account.runs.map(\.outcome) == [.ended])
        #expect(account.runs.allSatisfy { !$0.hasProblem })
        #expect(account.problemCount == 0)
        #expect(NightTimeline(account: account).problemTimes.isEmpty)

        let failures = JournalFailures(events: try journal.events())
        #expect(failures.failedRunCount == 0)
        #expect(failures.flags.isEmpty)
        #expect(failures.notices.isEmpty)
        #expect(failures.firstHeadline == nil)
    }
}
