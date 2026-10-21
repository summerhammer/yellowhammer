import Domain
@testable import Engine
import Foundation
@testable import Journal
import Repositories
import Testing

// roadmap P23.4 (spec: landing/open-one-pull-request-per-repository `#stack-notice`, landing/announce-a-partial-
// landing; sponsor ruling 2026-10-21 Q3; agent rulings 2026-10-21 items 4, 11 and 12, pending sponsor review):
// the pull request `base` is computed at landing from the Unmerged Feature Stack U as it then stands, and a
// stacked body carries the stack notice. Only the draft handed to the Publication stub is asserted.

@Suite("Land Act pull request: stacked base and stack notice (P23.4)")
struct FeatureBranchPullRequestStackTests {
    private func open(_ world: StackedLandWorld) async throws -> PullRequestDraft {
        let stub = StubPublicationAdapter(
            result: .success(.opened(url: "https://github.com/summerhammer/backend/pull/8"))
        )
        let seam = FeatureBranchPullRequest(publication: stub, clock: { landEpoch })
        let outcome = try await seam.open(
            try world.laneContext(), push: LanePushOutcome(pushed: true, commit: "deadbeef"), mergeOutcome: nil
        )
        #expect(outcome.opened)
        let calls = await stub.calls
        #expect(calls.count == 1)
        return try #require(calls.first)
    }

    private func stackedEvents(_ journal: JournalStore) throws -> [JournalEvent] {
        try journal.events(ofType: .pullRequestStacked).map(\.event)
    }

    private static let notice = """
        Stacked on #7 (`b1`) from Feature YLH-1. Merge #7 first. Merging this one first merges it into `b1`, not \
        `main`: it reaches mainline when #7 merges, and both then count. If #7 has merged and this pull request \
        still targets `b1`, change its base to `main` before merging.
        """

    @Test("A stacked Feature's pull request opens against the predecessor's branch, the notice first")
    func stackedDraftTargetsPredecessorBranch() async throws {
        let world = try await StackedLandWorld.make(name: "pr-stacked")
        try world.recordPredecessorPullRequest()
        #expect(try world.journal.effectiveBase(repository: "backend", excludingFeatureID: world.feature.id) != nil)

        let draft = try await open(world)

        #expect(draft.base == "b1")
        #expect(draft.head == landBranch.name)
        let lines = draft.body.components(separatedBy: "\n")
        #expect(lines[0].hasPrefix("**"))
        #expect(lines[1].isEmpty)
        #expect(lines[2] == Self.notice)
        #expect(lines[3].isEmpty)
        #expect(lines[4].hasPrefix("Feature: "))
        #expect(lines.filter { $0.hasPrefix("Stacked on") }.count == 1)
        #expect(try stackedEvents(world.journal) == [
            .pullRequestStacked(
                featureIssueID: "FEAT-1", repository: "backend", predecessorFeatureIssueID: "FEAT-0",
                predecessorBranch: "b1", predecessorPullRequestURL: "https://github.com/summerhammer/backend/pull/7"
            )
        ])
    }

    @Test("Once the predecessor's Observed Merge is recorded the draft targets the default branch, no notice")
    func mergedPredecessorDraftTargetsDefaultBranch() async throws {
        let world = try await StackedLandWorld.make(name: "pr-stacked-merged")
        try world.recordPredecessorPullRequest()
        #expect(try world.journal.effectiveBase(repository: "backend", excludingFeatureID: world.feature.id) != nil)
        try world.journal.recordLanding(
            featureID: world.predecessorID, repository: "backend", mainlineCommit: world.predecessorTip,
            evidence: .ancestry, now: landEpoch
        )
        #expect(try world.journal.effectiveBase(repository: "backend", excludingFeatureID: world.feature.id) == nil)

        let draft = try await open(world)

        // The recorded base still names `b1`; the landing base is computed from U as it stands now.
        #expect(try world.journal.featureBases(featureID: world.feature.id).first?.stackedOnFeatureID != nil)
        #expect(draft.base == "main")
        #expect(!draft.body.contains("Stacked on"))
        #expect(draft.body.hasPrefix("**"))
        #expect(draft.body.contains("\n\nFeature: "))
        #expect(try stackedEvents(world.journal).isEmpty)
    }

    @Test("A stacked Partial Landing keeps Lines 1-2 and the As-of stamp, and the notice follows the stamp")
    func stackedPartialLandingNoticeAfterStamp() async throws {
        let world = try await StackedLandWorld.make(name: "pr-stacked-partial", partial: true)
        try world.recordPredecessorPullRequest()

        let draft = try await open(world)

        #expect(draft.base == "b1")
        let lines = draft.body.components(separatedBy: "\n")
        #expect(lines[0].hasPrefix("**partial · "))
        #expect(lines[1].hasPrefix("This pull request is 1 of 1 for Feature "))
        #expect(lines[2].hasPrefix("*As of Night "))
        #expect(lines[3] == Self.notice)
        #expect(lines[4].isEmpty)
    }

    @Test("A predecessor with no recorded pull request is named in words; the event carries no URL")
    func predecessorWithoutRecordedPullRequest() async throws {
        let world = try await StackedLandWorld.make(name: "pr-stacked-no-prev")

        let draft = try await open(world)

        #expect(draft.base == "b1")
        #expect(draft.body.contains("Stacked on the predecessor's pull request (`b1`) from Feature YLH-1. "))
        #expect(try stackedEvents(world.journal) == [
            .pullRequestStacked(
                featureIssueID: "FEAT-1", repository: "backend", predecessorFeatureIssueID: "FEAT-0",
                predecessorBranch: "b1", predecessorPullRequestURL: nil
            )
        ])
    }
}
