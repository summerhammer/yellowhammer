import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
@testable import Journal
import Repositories
import Testing

// feature-authoring/select-the-next-feature #pull-request-read, "Which pull request" (OQ190 item 27): where the land
// Act recorded no URL, the gate reads the pull requests whose head is the Feature Branch and uses the one whose head
// is the Pushed Tip, else a merged one. These tests pin that fallback to the tested tip (M1 on PR #723, ruled by the
// Operator 2026-10-31): a merged pull request counts when its head descends from the Pushed Tip in this clone, or,
// when this clone lacks its head, when it is the only pull request the read found. An older merged pull request on
// the same branch is then no merge evidence for work pushed after it, whether this pass read it or an earlier pass
// recorded it, and an Operator's fix-up pushed after the land, then merged, still passes. Real git, local only; the
// read is a fake Port.

private let gateBranch = "yh-gate-feature"

/// A Publication Port fixture that answers every read with the same pull requests and records each query.
private actor FallbackPullRequestRead: Publication {
    private let answer: [ObservedPullRequest]
    private(set) var queries: [PullRequestQuery] = []

    init(_ answer: [ObservedPullRequest]) {
        self.answer = answer
    }

    func openPullRequest(_ draft: PullRequestDraft) async throws(PublicationError) -> PullRequestReceipt {
        throw .other("the predecessor gate never opens a pull request")
    }

    func readPullRequests(_ query: PullRequestQuery) async throws(PullRequestReadFailure) -> [ObservedPullRequest] {
        queries.append(query)
        return answer
    }
}

private func pullRequest(
    _ number: Int, state: ObservedPullRequestState, mergeCommit: String? = nil, head: String
) -> ObservedPullRequest {
    ObservedPullRequest(
        number: number, url: "https://github.com/o/backend/pull/\(number)", state: state, mergeCommit: mergeCommit,
        headCommit: head, headBranch: gateBranch, baseBranch: "main"
    )
}

private func revParse(_ ref: String, in repo: borrowing GateGitFixture) async -> String {
    await repo.run(["rev-parse", ref]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func repositories(_ repo: borrowing GateGitFixture) -> ProjectRepositories {
    ProjectRepositories(workingRepos: [Repo(name: "backend", path: repo.path, role: .backend)])
}

/// M1's history on one Feature Branch. Pull request #5 carried commit A and was squash-merged into `main`. The land
/// Act then pushed commit B, the Pushed Tip, and Code Hosting answered that a pull request already existed, so no URL
/// was recorded. Commit C came after the land; pull request #6, still open, has C as its head.
private struct TwoPullRequestHistory {
    let oldHead: String
    let oldSquash: String
    let pushedTip: String
    let newHead: String
}

private func populateTwoPullRequests(_ repo: borrowing GateGitFixture) async throws -> TwoPullRequestHistory {
    await repo.initRepo()
    _ = await repo.run(["remote", "add", "origin", "https://github.com/o/backend.git"])
    _ = try await repo.commit(filename: "shared.txt", content: "base\n", message: "init")
    _ = await repo.run(["checkout", "-b", gateBranch])
    let oldHead = try await repo.commit(filename: "feat.txt", content: "feature\n", message: "first part")
    _ = await repo.run(["checkout", "main"])
    _ = await repo.run(["merge", "--squash", gateBranch])
    _ = await repo.run(["commit", "-m", "squash of #5"])
    let oldSquash = await revParse("main", in: repo)
    _ = await repo.run(["checkout", gateBranch])
    let pushedTip = try await repo.commit(filename: "more.txt", content: "more\n", message: "second part")
    let newHead = try await repo.commit(filename: "more.txt", content: "more, after land\n", message: "post-land")
    _ = await repo.run(["checkout", "main"])
    return TwoPullRequestHistory(oldHead: oldHead, oldSquash: oldSquash, pushedTip: pushedTip, newHead: newHead)
}

/// The fix-up case: the land Act pushed the tip, the Operator pushed a fix-up to the same lines, then squash-merged.
/// The content test cannot see that merge (both add `feat.txt`, differently), so only the pull request test can.
private struct FixUpHistory {
    let pushedTip: String
    let fixUp: String
    let squash: String
}

private func populateFixUpThenSquash(_ repo: borrowing GateGitFixture) async throws -> FixUpHistory {
    await repo.initRepo()
    _ = await repo.run(["remote", "add", "origin", "https://github.com/o/backend.git"])
    _ = try await repo.commit(filename: "shared.txt", content: "base\n", message: "init")
    _ = await repo.run(["checkout", "-b", gateBranch])
    let pushedTip = try await repo.commit(filename: "feat.txt", content: "feature\n", message: "landed")
    let fixUp = try await repo.commit(filename: "feat.txt", content: "feature, fixed up\n", message: "fix-up")
    _ = await repo.run(["checkout", "main"])
    _ = await repo.run(["merge", "--squash", gateBranch])
    _ = await repo.run(["commit", "-m", "squash of #6"])
    return FixUpHistory(pushedTip: pushedTip, fixUp: fixUp, squash: await revParse("main", in: repo))
}

/// A full object name this clone does not have: a fix-up made on Code Hosting, which the clone never fetches.
private let unfetchedHead = String(repeating: "ab", count: 20)

/// A Feature landed at `tip` whose pull request was recorded with no URL, as when Code Hosting answered that one
/// already existed.
private func insertFeatureWithoutURL(
    _ journal: JournalStore, context: ActContext, runID: RunID, tip: String
) throws -> Int64 {
    let featureID = try insertGateFeature(
        journal, issueID: "FEAT-PR", branch: gateBranch, repositories: ["backend"], pushedTips: ["backend": tip]
    )
    try journal.recordPullRequest(
        featureID: featureID, repository: "backend", url: nil, nightID: context.night.id, runID: runID
    )
    return featureID
}

@Suite("Predecessor gate: the head-branch fallback is tied to the Pushed Tip (M1)")
struct PredecessorAncestryGateHeadBranchTests {
    @Test("An older merged pull request on the Feature Branch is no merge evidence for the Pushed Tip")
    func olderMergedPullRequestIsNotEvidence() async throws {
        let repo = GateGitFixture(name: "pr-m1-two")
        let history = try await populateTwoPullRequests(repo)
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let (context, runID) = try makeGateContext(journal, repositories: repositories(repo))
        let featureID = try insertFeatureWithoutURL(journal, context: context, runID: runID, tip: history.pushedTip)
        let read = FallbackPullRequestRead([
            pullRequest(5, state: .merged, mergeCommit: history.oldSquash, head: history.oldHead),
            pullRequest(6, state: .open, head: history.newHead)
        ])

        let outcome = try await PredecessorAncestryGate(publication: read).check(context, unmergedFeaturesMax: 1)

        #expect(singleUnmerged(outcome)?.repositories == ["backend"])
        #expect(try journal.landingEvidence(featureID: featureID).isEmpty)
        #expect(try journal.pullRequest(featureID: featureID, repository: "backend")?.observedState != .merged)
    }

    // M3 on PR #723: with no Pushed Tip recorded (a Feature pushed before its commit was, ruling 2026-10-11 item 9),
    // the tested tip is the Feature Branch head. The read used to choose against the branch's name, which no pull
    // request's head commit equals, so it recorded nothing while the test went on against the branch head.
    @Test("With no Pushed Tip, the read records the pull request whose head is the Feature Branch head")
    func noPushedTipRecordsThePullRequestAtTheBranchHead() async throws {
        let repo = GateGitFixture(name: "pr-m3-no-pushed-tip")
        let history = try await populateTwoPullRequests(repo)
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let (context, runID) = try makeGateContext(journal, repositories: repositories(repo))
        let featureID = try insertGateFeature(
            journal, issueID: "FEAT-PR", branch: gateBranch, repositories: ["backend"]
        )
        try journal.recordPullRequest(
            featureID: featureID, repository: "backend", url: nil, nightID: context.night.id, runID: runID
        )
        #expect(try journal.pushedTips(featureID: featureID).isEmpty)
        // #5's merge commit is mainline's head, so the pull request test would hold if it chose #5.
        let read = FallbackPullRequestRead([
            pullRequest(5, state: .merged, mergeCommit: history.oldSquash, head: history.oldHead),
            pullRequest(6, state: .open, head: history.newHead)
        ])

        let outcome = try await PredecessorAncestryGate(publication: read).check(context, unmergedFeaturesMax: 1)

        let recorded = try journal.pullRequest(featureID: featureID, repository: "backend")
        #expect(recorded?.observedState == .open)
        #expect(recorded?.number == 6)
        #expect(recorded?.headCommit == history.newHead)
        #expect(try journal.landingEvidence(featureID: featureID).isEmpty)
        #expect(singleUnmerged(outcome)?.repositories == ["backend"])
    }

    @Test("A merged state an earlier pass recorded by head branch is re-checked against the Pushed Tip")
    func recordedFallbackMergeIsRechecked() async throws {
        let repo = GateGitFixture(name: "pr-m1-recorded")
        let history = try await populateTwoPullRequests(repo)
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let (context, runID) = try makeGateContext(journal, repositories: repositories(repo))
        let featureID = try insertFeatureWithoutURL(journal, context: context, runID: runID, tip: history.pushedTip)
        let oldMerged = pullRequest(5, state: .merged, mergeCommit: history.oldSquash, head: history.oldHead)
        try journal.recordObservedPullRequest(
            featureID: featureID, repository: "backend", observed: oldMerged, runID: runID
        )
        let read = FallbackPullRequestRead([oldMerged, pullRequest(6, state: .open, head: history.newHead)])

        let outcome = try await PredecessorAncestryGate(publication: read).check(context, unmergedFeaturesMax: 1)

        #expect(singleUnmerged(outcome)?.repositories == ["backend"])
        #expect(try journal.landingEvidence(featureID: featureID).isEmpty)
        let byHead = PullRequestQuery(owner: "o", repository: "backend", selector: .headBranch(gateBranch))
        #expect(await read.queries == [byHead])
    }

    @Test("A merged state recorded by head branch whose head descends from the Pushed Tip stands without a read")
    func recordedFallbackMergeAtAFixUpStands() async throws {
        let repo = GateGitFixture(name: "pr-m1-recorded-fixup")
        let history = try await populateFixUpThenSquash(repo)
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let (context, runID) = try makeGateContext(journal, repositories: repositories(repo))
        let featureID = try insertFeatureWithoutURL(journal, context: context, runID: runID, tip: history.pushedTip)
        try journal.recordObservedPullRequest(
            featureID: featureID, repository: "backend",
            observed: pullRequest(6, state: .merged, mergeCommit: history.squash, head: history.fixUp), runID: runID
        )
        let read = FallbackPullRequestRead([])

        let outcome = try await PredecessorAncestryGate(publication: read).check(context, unmergedFeaturesMax: 1)

        #expect(outcome == .open)
        #expect(try journal.landingEvidence(featureID: featureID) == ["backend": .pullRequest])
        #expect(await read.queries.isEmpty)
    }

    @Test("A fix-up pushed after the land, then squash-merged, still passes: its head descends from the Pushed Tip")
    func fixUpThenMergePasses() async throws {
        let repo = GateGitFixture(name: "pr-m1-fixup")
        let history = try await populateFixUpThenSquash(repo)
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let (context, runID) = try makeGateContext(journal, repositories: repositories(repo))
        let featureID = try insertFeatureWithoutURL(journal, context: context, runID: runID, tip: history.pushedTip)
        let read = FallbackPullRequestRead([
            pullRequest(6, state: .merged, mergeCommit: history.squash, head: history.fixUp)
        ])

        let outcome = try await PredecessorAncestryGate(publication: read).check(context, unmergedFeaturesMax: 1)

        #expect(outcome == .open)
        #expect(try journal.landingEvidence(featureID: featureID) == ["backend": .pullRequest])
        #expect(try journal.landingCommits(featureID: featureID) == ["backend": history.squash])
    }

    @Test("A fix-up made on Code Hosting, its head not in this clone, passes when it is the only pull request read")
    func unfetchedFixUpPassesAsTheSolePullRequest() async throws {
        let repo = GateGitFixture(name: "pr-m1-unfetched")
        let history = try await populateFixUpThenSquash(repo)
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let (context, runID) = try makeGateContext(journal, repositories: repositories(repo))
        let featureID = try insertFeatureWithoutURL(journal, context: context, runID: runID, tip: history.pushedTip)
        let read = FallbackPullRequestRead([
            pullRequest(6, state: .merged, mergeCommit: history.squash, head: unfetchedHead)
        ])

        let outcome = try await PredecessorAncestryGate(publication: read).check(context, unmergedFeaturesMax: 1)

        #expect(outcome == .open)
        #expect(try journal.landingEvidence(featureID: featureID) == ["backend": .pullRequest])
        #expect(try journal.landingCommits(featureID: featureID) == ["backend": history.squash])
    }

    @Test("A merged pull request whose head this clone lacks is not used when the read found another one")
    func unfetchedHeadAmongSeveralIsNotUsed() async throws {
        let repo = GateGitFixture(name: "pr-m1-unfetched-two")
        let history = try await populateFixUpThenSquash(repo)
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let (context, runID) = try makeGateContext(journal, repositories: repositories(repo))
        let featureID = try insertFeatureWithoutURL(journal, context: context, runID: runID, tip: history.pushedTip)
        let read = FallbackPullRequestRead([
            pullRequest(5, state: .closedWithoutMerge, head: "f00dfeed"),
            pullRequest(6, state: .merged, mergeCommit: history.squash, head: unfetchedHead)
        ])

        let outcome = try await PredecessorAncestryGate(publication: read).check(context, unmergedFeaturesMax: 1)

        #expect(singleUnmerged(outcome)?.repositories == ["backend"])
        #expect(try journal.landingEvidence(featureID: featureID).isEmpty)
        let multiple = try journal.events(ofType: .multiplePullRequestsObserved).map(\.event)
        #expect(multiple == [.multiplePullRequestsObserved(repository: "backend", branch: gateBranch, numbers: [5, 6])])
    }
}
