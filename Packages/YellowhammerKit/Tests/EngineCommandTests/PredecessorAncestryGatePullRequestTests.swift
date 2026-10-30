import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
@testable import Journal
import Repositories
import Testing

// feature-authoring/select-the-next-feature #merge-test (its second rung) and #pull-request-read (OQ190 items 8,
// 9, 10, 22, 23, 26, 27 and 28; issue #698): after ancestry does not hold, the gate reads the Feature's pull
// request through the Publication Port. A pull request read merged whose merge commit is in the fetched mainline,
// checked locally, records the Observed Merge with `pull_request` evidence and the merge commit as its landing
// commit. A read that cannot be made records one `PullRequestReadFailed` per repository per pass and falls through
// to the content test, which a read never overrules. Real git, local only; the read is a fake Port.

private let gateBranch = "yh-gate-feature"
private let otherBranch = "yh-other-feature"
private let recordedURL = "https://github.com/o/backend/pull/12"

/// A Publication Port fixture for the gate: answers every read the same way and records each query. The gate
/// never opens a pull request.
private actor FakePullRequestRead: Publication {
    enum Answer {
        case found([ObservedPullRequest])
        case failed(PullRequestReadFailure.Reason)
    }

    private let answer: Answer
    private(set) var queries: [PullRequestQuery] = []

    init(_ answer: Answer) {
        self.answer = answer
    }

    func openPullRequest(_ draft: PullRequestDraft) async throws(PublicationError) -> PullRequestReceipt {
        throw .other("the predecessor gate never opens a pull request")
    }

    func readPullRequests(_ query: PullRequestQuery) async throws(PullRequestReadFailure) -> [ObservedPullRequest] {
        queries.append(query)
        switch answer {
        case .found(let pullRequests):
            return pullRequests
        case .failed(let reason):
            throw PullRequestReadFailure(reason, detail: "scripted by the gate fixture")
        }
    }
}

private func pullRequest(
    _ number: Int = 12, state: ObservedPullRequestState = .merged, mergeCommit: String?, head: String,
    base: String = "main"
) -> ObservedPullRequest {
    ObservedPullRequest(
        number: number, url: "https://github.com/o/backend/pull/\(number)", state: state, mergeCommit: mergeCommit,
        headCommit: head, headBranch: gateBranch, baseBranch: base
    )
}

private func revParse(_ ref: String, in repo: borrowing GateGitFixture) async -> String {
    await repo.run(["rev-parse", ref]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func repositories(_ repo: borrowing GateGitFixture) -> ProjectRepositories {
    ProjectRepositories(workingRepos: [Repo(name: "backend", path: repo.path, role: .backend)])
}

/// A repository whose GitHub `origin` is `o/backend` (never fetched), with `yh-gate-feature` landed at its Pushed
/// Tip (a new file and an edit of `shared.txt`); `main` is left checked out at the base. Returns the Pushed Tip.
private func populateLandedFeature(_ repo: borrowing GateGitFixture, origin: Bool = true) async throws -> String {
    await repo.initRepo()
    if origin {
        _ = await repo.run(["remote", "add", "origin", "https://github.com/o/backend.git"])
    }
    _ = try await repo.commit(filename: "shared.txt", content: "base\nline two\nline three\n", message: "init")
    _ = await repo.run(["checkout", "-b", gateBranch])
    _ = try await repo.commit(filename: "feat.txt", content: "feature\n", message: "add feat")
    let tip = try await repo.commit(
        filename: "shared.txt", content: "base\nline two\nfeature line three\n", message: "edit shared"
    )
    _ = await repo.run(["checkout", "main"])
    return tip
}

/// #698's case: after the land Act pushed the tip, the Operator edited the pull request's branch, then squash-merged
/// it. Mainline's squash commit differs from the Pushed Tip, so the content test cannot see the merge. Returns the
/// squash commit.
private func squashMergeWithPostLandEdits(_ repo: borrowing GateGitFixture) async throws -> String {
    _ = await repo.run(["checkout", gateBranch])
    _ = try await repo.commit(filename: "feat.txt", content: "feature, edited on review\n", message: "post-land edit")
    _ = await repo.run(["checkout", "main"])
    return await squashMerge(repo)
}

/// A plain squash merge of the branch as the land Act pushed it: the content test sees it. Returns the squash commit.
private func squashMerge(_ repo: borrowing GateGitFixture) async -> String {
    _ = await repo.run(["merge", "--squash", gateBranch])
    _ = await repo.run(["commit", "-m", "squash of \(gateBranch)"])
    return await revParse("main", in: repo)
}

/// The landed Feature, with the pull request the land Act recorded: `url`, or none when GitHub answered that one
/// already existed (`url: nil`). `recordPullRequest: false` records no pull request at all.
private func insertLandedFeature(
    _ journal: JournalStore, context: ActContext, runID: RunID, tip: String, url: String?,
    recordPullRequest: Bool = true
) throws -> Int64 {
    let featureID = try insertGateFeature(
        journal, issueID: "FEAT-PR", branch: gateBranch, repositories: ["backend"], pushedTips: ["backend": tip]
    )
    if recordPullRequest {
        try journal.recordPullRequest(
            featureID: featureID, repository: "backend", url: url, nightID: context.night.id, runID: runID
        )
    }
    return featureID
}

private func readFailures(_ journal: JournalStore) throws -> [JournalEvent] {
    try journal.events(ofType: .pullRequestReadFailed).map(\.event)
}

@Suite("Predecessor gate: the pull request test (OQ190)")
struct PredecessorAncestryGatePullRequestTests {
    @Test("#698: a squash merge of a branch edited after land is observed by its merged pull request")
    func mergedPullRequestObservesAnEditedSquash() async throws {
        let repo = GateGitFixture(name: "pr-698")
        let tip = try await populateLandedFeature(repo)
        let squash = try await squashMergeWithPostLandEdits(repo)
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let (context, runID) = try makeGateContext(journal, repositories: repositories(repo))
        let featureID = try insertLandedFeature(journal, context: context, runID: runID, tip: tip, url: recordedURL)
        let read = FakePullRequestRead(.found([pullRequest(mergeCommit: squash, head: "f00dfeed")]))

        let outcome = try await PredecessorAncestryGate(publication: read).check(context, unmergedFeaturesMax: 1)

        #expect(outcome == .open)
        #expect(try journal.landingEvidence(featureID: featureID) == ["backend": .pullRequest])
        #expect(try journal.landingCommits(featureID: featureID) == ["backend": squash])
        #expect(try journal.landings(featureID: featureID) == ["backend": squash])
        #expect(await read.queries == [PullRequestQuery(owner: "o", repository: "backend", selector: .number(12))])
        #expect(try readFailures(journal).isEmpty)
    }

    @Test("Without the pull request test, #698's squash stays unmerged: the content test cannot see it")
    func contentAloneMissesTheEditedSquash() async throws {
        let repo = GateGitFixture(name: "pr-698-content")
        let tip = try await populateLandedFeature(repo)
        _ = try await squashMergeWithPostLandEdits(repo)
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let (context, runID) = try makeGateContext(journal, repositories: repositories(repo))
        let featureID = try insertLandedFeature(journal, context: context, runID: runID, tip: tip, url: recordedURL)
        let read = FakePullRequestRead(.found([]))

        let outcome = try await PredecessorAncestryGate(publication: read).check(context, unmergedFeaturesMax: 1)

        #expect(singleUnmerged(outcome)?.repositories == ["backend"])
        #expect(try journal.landingEvidence(featureID: featureID).isEmpty)
        #expect(try readFailures(journal).isEmpty)
    }

    @Test("A failed read records PullRequestReadFailed with its reason, and #698's squash stays unmerged")
    func failedReadIsRecordedAndTheFeatureStaysUnmerged() async throws {
        let repo = GateGitFixture(name: "pr-failed")
        let tip = try await populateLandedFeature(repo)
        _ = try await squashMergeWithPostLandEdits(repo)
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let (context, runID) = try makeGateContext(journal, repositories: repositories(repo))
        let featureID = try insertLandedFeature(journal, context: context, runID: runID, tip: tip, url: recordedURL)
        let read = FakePullRequestRead(.failed(.rateLimited))

        let outcome = try await PredecessorAncestryGate(publication: read).check(context, unmergedFeaturesMax: 1)

        #expect(singleUnmerged(outcome)?.repositories == ["backend"])
        #expect(try journal.landingEvidence(featureID: featureID).isEmpty)
        #expect(try readFailures(journal) == [.pullRequestReadFailed(repository: "backend", reason: .rateLimited)])
        #expect(try journal.events(ofType: .actIncomplete).isEmpty)
    }

    @Test("A failed read falls through to the content test, which still observes a plain squash merge")
    func failedReadFallsThroughToContent() async throws {
        let repo = GateGitFixture(name: "pr-failed-content")
        let tip = try await populateLandedFeature(repo)
        let squash = await squashMerge(repo)
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let (context, runID) = try makeGateContext(journal, repositories: repositories(repo))
        let featureID = try insertLandedFeature(journal, context: context, runID: runID, tip: tip, url: recordedURL)
        let read = FakePullRequestRead(.failed(.unreachable))

        let outcome = try await PredecessorAncestryGate(publication: read).check(context, unmergedFeaturesMax: 1)

        #expect(outcome == .open)
        #expect(try journal.landingEvidence(featureID: featureID) == ["backend": .content])
        #expect(try journal.landingCommits(featureID: featureID) == ["backend": squash])
        #expect(try readFailures(journal) == [.pullRequestReadFailed(repository: "backend", reason: .unreachable)])
    }

    @Test("Two Features failing to read in one repository record one PullRequestReadFailed in the pass")
    func oneFailurePerRepositoryPerPass() async throws {
        let repo = GateGitFixture(name: "pr-failed-once")
        let tip = try await populateLandedFeature(repo)
        _ = await repo.run(["checkout", "-b", otherBranch])
        let otherTip = try await repo.commit(filename: "other.txt", content: "other\n", message: "other feature")
        _ = await repo.run(["checkout", "main"])
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let (context, runID) = try makeGateContext(journal, repositories: repositories(repo))
        _ = try insertLandedFeature(journal, context: context, runID: runID, tip: tip, url: recordedURL)
        let otherID = try insertGateFeature(
            journal, issueID: "FEAT-OTHER", branch: otherBranch, repositories: ["backend"],
            pushedTips: ["backend": otherTip]
        )
        try journal.recordPullRequest(
            featureID: otherID, repository: "backend", url: "https://github.com/o/backend/pull/13",
            nightID: context.night.id, runID: runID
        )
        let read = FakePullRequestRead(.failed(.noAccess))

        _ = try await PredecessorAncestryGate(publication: read).check(context, unmergedFeaturesMax: 3)

        #expect(await read.queries.count == 2)
        #expect(try readFailures(journal) == [.pullRequestReadFailed(repository: "backend", reason: .noAccess)])
    }

    @Test("Finding no pull request for the head branch is no failure: no event, and the content test runs")
    func noPullRequestFound() async throws {
        let repo = GateGitFixture(name: "pr-none")
        let tip = try await populateLandedFeature(repo)
        _ = await squashMerge(repo)
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let (context, runID) = try makeGateContext(journal, repositories: repositories(repo))
        let featureID = try insertLandedFeature(journal, context: context, runID: runID, tip: tip, url: nil)
        let read = FakePullRequestRead(.found([]))

        let outcome = try await PredecessorAncestryGate(publication: read).check(context, unmergedFeaturesMax: 1)

        #expect(outcome == .open)
        #expect(try journal.landingEvidence(featureID: featureID) == ["backend": .content])
        let byHead = PullRequestQuery(owner: "o", repository: "backend", selector: .headBranch(gateBranch))
        #expect(await read.queries == [byHead])
        #expect(try readFailures(journal).isEmpty)
    }

    @Test("A pull request merged into a lower Feature's branch does not pass while its merge commit is not in mainline")
    func mergedIntoALowerBranchWaitsForMainline() async throws {
        let repo = GateGitFixture(name: "pr-lower")
        let tip = try await populateLandedFeature(repo)
        _ = try await squashMergeWithPostLandEdits(repo)
        _ = await repo.run(["checkout", "-b", otherBranch, "main~1"])
        let lowerMerge = try await repo.commit(filename: "lower.txt", content: "lower\n", message: "merged into lower")
        _ = await repo.run(["checkout", "main"])
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let (context, runID) = try makeGateContext(journal, repositories: repositories(repo))
        let featureID = try insertLandedFeature(journal, context: context, runID: runID, tip: tip, url: recordedURL)
        let read = FakePullRequestRead(.found([pullRequest(mergeCommit: lowerMerge, head: tip, base: otherBranch)]))

        let outcome = try await PredecessorAncestryGate(publication: read).check(context, unmergedFeaturesMax: 1)

        #expect(singleUnmerged(outcome)?.repositories == ["backend"])
        #expect(try journal.landingEvidence(featureID: featureID).isEmpty)
        #expect(try readFailures(journal).isEmpty)
    }

    @Test("A pull request merged into a lower branch passes once that merge commit reaches mainline")
    func mergedIntoALowerBranchPassesOnceInMainline() async throws {
        let repo = GateGitFixture(name: "pr-lower-merged")
        let tip = try await populateLandedFeature(repo)
        _ = try await squashMergeWithPostLandEdits(repo)
        _ = await repo.run(["checkout", "-b", otherBranch, "main~1"])
        let lowerMerge = try await repo.commit(filename: "lower.txt", content: "lower\n", message: "merged into lower")
        _ = await repo.run(["checkout", "main"])
        _ = await repo.run(["merge", "--no-ff", "-m", "merge the lower branch", otherBranch])
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let (context, runID) = try makeGateContext(journal, repositories: repositories(repo))
        let featureID = try insertLandedFeature(journal, context: context, runID: runID, tip: tip, url: recordedURL)
        let read = FakePullRequestRead(.found([pullRequest(mergeCommit: lowerMerge, head: tip, base: otherBranch)]))

        let outcome = try await PredecessorAncestryGate(publication: read).check(context, unmergedFeaturesMax: 1)

        #expect(outcome == .open)
        #expect(try journal.landingEvidence(featureID: featureID) == ["backend": .pullRequest])
        #expect(try journal.landingCommits(featureID: featureID) == ["backend": lowerMerge])
    }

    @Test("A merge commit missing from the local clone reads as not in mainline")
    func mergeCommitMissingFromTheClone() async throws {
        let repo = GateGitFixture(name: "pr-missing")
        let tip = try await populateLandedFeature(repo)
        _ = try await squashMergeWithPostLandEdits(repo)
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let (context, runID) = try makeGateContext(journal, repositories: repositories(repo))
        let featureID = try insertLandedFeature(journal, context: context, runID: runID, tip: tip, url: recordedURL)
        let absent = String(repeating: "ab", count: 20)
        let read = FakePullRequestRead(.found([pullRequest(mergeCommit: absent, head: tip)]))

        let outcome = try await PredecessorAncestryGate(publication: read).check(context, unmergedFeaturesMax: 1)

        #expect(singleUnmerged(outcome)?.repositories == ["backend"])
        #expect(try journal.landingEvidence(featureID: featureID).isEmpty)
    }

    @Test("By head branch, the pull request whose head is the Pushed Tip is the one used")
    func headLookupPrefersThePushedTip() async throws {
        let repo = GateGitFixture(name: "pr-head-tip")
        let tip = try await populateLandedFeature(repo)
        let squash = try await squashMergeWithPostLandEdits(repo)
        _ = await repo.run(["checkout", "-b", otherBranch, "main~1"])
        let sideCommit = try await repo.commit(filename: "side.txt", content: "side\n", message: "not in mainline")
        _ = await repo.run(["checkout", "main"])
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let (context, runID) = try makeGateContext(journal, repositories: repositories(repo))
        let featureID = try insertLandedFeature(journal, context: context, runID: runID, tip: tip, url: nil)
        let read = FakePullRequestRead(.found([
            pullRequest(5, mergeCommit: sideCommit, head: "f00dfeed"),
            pullRequest(6, mergeCommit: squash, head: tip)
        ]))

        let outcome = try await PredecessorAncestryGate(publication: read).check(context, unmergedFeaturesMax: 1)

        #expect(outcome == .open)
        #expect(try journal.landingEvidence(featureID: featureID) == ["backend": .pullRequest])
        #expect(try journal.landingCommits(featureID: featureID) == ["backend": squash])
    }

    @Test("By head branch, with no pull request at the Pushed Tip, a merged one is used")
    func headLookupFallsBackToAMergedOne() async throws {
        let repo = GateGitFixture(name: "pr-head-merged")
        let tip = try await populateLandedFeature(repo)
        let squash = try await squashMergeWithPostLandEdits(repo)
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let (context, runID) = try makeGateContext(journal, repositories: repositories(repo))
        let featureID = try insertLandedFeature(
            journal, context: context, runID: runID, tip: tip, url: nil, recordPullRequest: false
        )
        let read = FakePullRequestRead(.found([
            pullRequest(5, state: .closedWithoutMerge, mergeCommit: nil, head: "f00dfeed"),
            pullRequest(6, mergeCommit: squash, head: "decafbad")
        ]))

        let outcome = try await PredecessorAncestryGate(publication: read).check(context, unmergedFeaturesMax: 1)

        #expect(outcome == .open)
        #expect(try journal.landingEvidence(featureID: featureID) == ["backend": .pullRequest])
        #expect(try journal.landingCommits(featureID: featureID) == ["backend": squash])
    }

    @Test("A pull request read open or closed never overrules the content test", arguments: [
        ObservedPullRequestState.open, .closedWithoutMerge
    ])
    func openOrClosedNeverOverrulesContent(state: ObservedPullRequestState) async throws {
        let repo = GateGitFixture(name: "pr-never-overrules")
        let tip = try await populateLandedFeature(repo)
        _ = await squashMerge(repo)
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let (context, runID) = try makeGateContext(journal, repositories: repositories(repo))
        let featureID = try insertLandedFeature(journal, context: context, runID: runID, tip: tip, url: recordedURL)
        let read = FakePullRequestRead(.found([pullRequest(state: state, mergeCommit: nil, head: tip)]))

        let outcome = try await PredecessorAncestryGate(publication: read).check(context, unmergedFeaturesMax: 1)

        #expect(outcome == .open)
        #expect(try journal.landingEvidence(featureID: featureID) == ["backend": .content])
    }

    @Test("Where ancestry holds, the evidence is ancestry; the pull request is still read, for its state (item 16)")
    func ancestryFirst() async throws {
        let repo = GateGitFixture(name: "pr-ancestry-first")
        let tip = try await populateLandedFeature(repo)
        _ = await repo.run(["merge", "--no-ff", "-m", "merge", gateBranch])
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let (context, runID) = try makeGateContext(journal, repositories: repositories(repo))
        let featureID = try insertLandedFeature(journal, context: context, runID: runID, tip: tip, url: recordedURL)
        let read = FakePullRequestRead(.failed(.unreachable))

        let outcome = try await PredecessorAncestryGate(publication: read).check(context, unmergedFeaturesMax: 1)

        #expect(outcome == .open)
        #expect(try journal.landingEvidence(featureID: featureID) == ["backend": .ancestry])
        #expect(await read.queries.count == 1)
        #expect(try readFailures(journal) == [.pullRequestReadFailed(repository: "backend", reason: .unreachable)])
    }

    @Test("A repository whose origin is not on GitHub is not read, and records no failure")
    func noGitHubOriginIsNotRead() async throws {
        let repo = GateGitFixture(name: "pr-no-origin")
        let tip = try await populateLandedFeature(repo, origin: false)
        _ = await squashMerge(repo)
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let (context, runID) = try makeGateContext(journal, repositories: repositories(repo))
        let featureID = try insertLandedFeature(journal, context: context, runID: runID, tip: tip, url: recordedURL)
        let read = FakePullRequestRead(.failed(.unreachable))

        let outcome = try await PredecessorAncestryGate(publication: read).check(context, unmergedFeaturesMax: 1)

        #expect(outcome == .open)
        #expect(try journal.landingEvidence(featureID: featureID) == ["backend": .content])
        #expect(await read.queries.isEmpty)
        #expect(try readFailures(journal).isEmpty)
    }
}
