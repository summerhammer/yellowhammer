import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
@testable import Journal
import Repositories
import Testing

// feature-authoring/select-the-next-feature #pull-request-read ("Which pull request", "What it records"; OQ190
// items 14, 16, 27 and 28; issue #717): each pass reads the pull request of every pushed repository of every Feature
// in U, including repositories that already have an Observed Merge, until it reads merged or its Feature leaves U.
// Each successful read records the last observed state and when it was observed; a failed read leaves them. The
// state never changes a recorded Observed Merge. Real git, local only; the read is a fake Port.

private let stateBranch = "yh-state-feature"
private let lowerBranch = "yh-state-lower"

/// A Publication Port fixture answering per repository, whose answers a test can change between passes. A
/// repository with no answer reads as no pull request found.
private actor ScriptedPullRequestRead: Publication {
    enum Answer {
        case found([ObservedPullRequest])
        case failed(PullRequestReadFailure.Reason)
    }

    private var answers: [String: Answer]
    private(set) var queries: [PullRequestQuery] = []

    init(_ answers: [String: Answer]) {
        self.answers = answers
    }

    func answer(_ repository: String, with answer: Answer) {
        answers[repository] = answer
    }

    func queried(_ repository: String) -> [PullRequestQuery] {
        queries.filter { $0.repository == repository }
    }

    func openPullRequest(_ draft: PullRequestDraft) async throws(PublicationError) -> PullRequestReceipt {
        throw .other("the predecessor gate never opens a pull request")
    }

    func readPullRequests(_ query: PullRequestQuery) async throws(PullRequestReadFailure) -> [ObservedPullRequest] {
        queries.append(query)
        switch answers[query.repository] {
        case .found(let pullRequests):
            return pullRequests
        case .failed(let reason):
            throw PullRequestReadFailure(reason, detail: "scripted by the gate fixture")
        case nil:
            return []
        }
    }
}

private func observed(
    _ repository: String, _ number: Int, state: ObservedPullRequestState, mergeCommit: String? = nil,
    head: String, base: String = "main"
) -> ObservedPullRequest {
    ObservedPullRequest(
        number: number, url: "https://github.com/o/\(repository)/pull/\(number)", state: state,
        mergeCommit: mergeCommit, headCommit: head, headBranch: stateBranch, baseBranch: base
    )
}

private func url(_ repository: String, _ number: Int) -> String {
    "https://github.com/o/\(repository)/pull/\(number)"
}

/// A repository whose GitHub `origin` is `o/<name>`, with `yh-state-feature` one commit ahead of `main`, which is
/// left checked out. Returns the Pushed Tip.
private func populateFeature(_ repo: borrowing GateGitFixture, name: String) async throws -> String {
    await repo.initRepo()
    _ = await repo.run(["remote", "add", "origin", "https://github.com/o/\(name).git"])
    _ = try await repo.commit(filename: "base.txt", content: "base\n", message: "init")
    _ = await repo.run(["checkout", "-b", stateBranch])
    let tip = try await repo.commit(filename: "\(name).txt", content: "feature\n", message: "feature")
    _ = await repo.run(["checkout", "main"])
    return tip
}

private func headCommit(_ ref: String, in repo: borrowing GateGitFixture) async -> String {
    await repo.run(["rev-parse", ref]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func repositories(_ repos: [(String, String)]) -> ProjectRepositories {
    ProjectRepositories(workingRepos: repos.map { Repo(name: $0.0, path: $0.1, role: .backend) })
}

private func readFailures(_ journal: JournalStore) throws -> [JournalEvent] {
    try journal.events(ofType: .pullRequestReadFailed).map(\.event)
}

@Suite("Predecessor gate: the last observed pull request state (#717)")
struct PullRequestObservedStateGateTests {
    @Test("A successful read records the state, its time, the number, the head and merge commits and the base")
    func successfulReadRecordsTheState() async throws {
        let repo = GateGitFixture(name: "state-open")
        let tip = try await populateFeature(repo, name: "backend")
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let (context, runID) = try makeGateContext(journal, repositories: repositories([("backend", repo.path)]))
        let featureID = try insertGateFeature(
            journal, issueID: "FEAT-S", branch: stateBranch, repositories: ["backend"], pushedTips: ["backend": tip]
        )
        try journal.recordPullRequest(
            featureID: featureID, repository: "backend", url: url("backend", 12), nightID: context.night.id,
            runID: runID
        )
        let read = ScriptedPullRequestRead(["backend": .found([observed("backend", 12, state: .open, head: tip)])])
        let before = Date().addingTimeInterval(-1)

        let outcome = try await PredecessorAncestryGate(publication: read).check(context, unmergedFeaturesMax: 1)

        #expect(singleUnmerged(outcome)?.repositories == ["backend"])
        let record = try #require(try journal.pullRequest(featureID: featureID, repository: "backend"))
        #expect(record.observedState == .open)
        let observedAt = try #require(record.observedAt)
        #expect(observedAt >= before)
        #expect(record.number == 12)
        #expect(record.headCommit == tip)
        #expect(record.mergeCommit == nil)
        #expect(record.baseBranch == "main")
    }

    @Test("A failed read leaves the last state and its time; a later successful read overwrites them")
    func failedReadKeepsTheLastState() async throws {
        let repo = GateGitFixture(name: "state-failed")
        let tip = try await populateFeature(repo, name: "backend")
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let (context, runID) = try makeGateContext(journal, repositories: repositories([("backend", repo.path)]))
        let featureID = try insertGateFeature(
            journal, issueID: "FEAT-S", branch: stateBranch, repositories: ["backend"], pushedTips: ["backend": tip]
        )
        try journal.recordPullRequest(
            featureID: featureID, repository: "backend", url: url("backend", 12), nightID: context.night.id,
            runID: runID
        )
        let read = ScriptedPullRequestRead(["backend": .found([observed("backend", 12, state: .open, head: tip)])])
        let gate = PredecessorAncestryGate(publication: read)
        _ = try await gate.check(context, unmergedFeaturesMax: 1)
        let first = try #require(try journal.pullRequest(featureID: featureID, repository: "backend"))

        await read.answer("backend", with: .failed(.unreachable))
        _ = try await gate.check(context, unmergedFeaturesMax: 1)

        let afterFailure = try #require(try journal.pullRequest(featureID: featureID, repository: "backend"))
        #expect(afterFailure.observedState == .open)
        #expect(afterFailure.observedAt == first.observedAt)
        #expect(try readFailures(journal) == [.pullRequestReadFailed(repository: "backend", reason: .unreachable)])

        await read.answer(
            "backend", with: .found([observed("backend", 12, state: .closedWithoutMerge, head: tip)])
        )
        _ = try await gate.check(context, unmergedFeaturesMax: 1)

        let afterClose = try #require(try journal.pullRequest(featureID: featureID, repository: "backend"))
        #expect(afterClose.observedState == .closedWithoutMerge)
        #expect(await read.queried("backend").count == 3)
    }

    @Test("A pull request recorded without a URL gets the URL and number of the one the head-branch read found")
    func alreadyOpenRowGetsItsURLAndNumber() async throws {
        let repo = GateGitFixture(name: "state-already-open")
        let tip = try await populateFeature(repo, name: "backend")
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let (context, runID) = try makeGateContext(journal, repositories: repositories([("backend", repo.path)]))
        let featureID = try insertGateFeature(
            journal, issueID: "FEAT-S", branch: stateBranch, repositories: ["backend"], pushedTips: ["backend": tip]
        )
        try journal.recordPullRequest(
            featureID: featureID, repository: "backend", url: nil, nightID: context.night.id, runID: runID
        )
        let read = ScriptedPullRequestRead(["backend": .found([
            observed("backend", 4, state: .closedWithoutMerge, head: "f00dfeed"),
            observed("backend", 7, state: .open, head: tip)
        ])])

        _ = try await PredecessorAncestryGate(publication: read).check(context, unmergedFeaturesMax: 1)

        #expect(await read.queries == [
            PullRequestQuery(owner: "o", repository: "backend", selector: .headBranch(stateBranch))
        ])
        let record = try #require(try journal.pullRequest(featureID: featureID, repository: "backend"))
        #expect(record.url == url("backend", 7))
        #expect(record.number == 7)
        #expect(record.observedState == .open)
    }

    @Test("A pushed repository with no recorded pull request is read, and the read records nothing")
    func noRecordedPullRequestIsNotInserted() async throws {
        let repo = GateGitFixture(name: "state-no-row")
        let tip = try await populateFeature(repo, name: "backend")
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let (context, _) = try makeGateContext(journal, repositories: repositories([("backend", repo.path)]))
        let featureID = try insertGateFeature(
            journal, issueID: "FEAT-S", branch: stateBranch, repositories: ["backend"], pushedTips: ["backend": tip]
        )
        let read = ScriptedPullRequestRead(["backend": .found([observed("backend", 7, state: .open, head: tip)])])

        _ = try await PredecessorAncestryGate(publication: read).check(context, unmergedFeaturesMax: 1)

        #expect(await read.queried("backend").count == 1)
        #expect(try journal.pullRequests(featureID: featureID).isEmpty)
    }

    @Test("A repository that already has an Observed Merge is read and its state recorded; its merge never changes")
    func mergedRepositoryIsReadButItsObservedMergeNeverChanges() async throws {
        let backend = GateGitFixture(name: "state-merged-backend")
        let mobile = GateGitFixture(name: "state-merged-mobile")
        let backendTip = try await populateFeature(backend, name: "backend")
        let mobileTip = try await populateFeature(mobile, name: "mobile")
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let (context, runID) = try makeGateContext(
            journal, repositories: repositories([("backend", backend.path), ("mobile", mobile.path)])
        )
        let featureID = try insertGateFeature(
            journal, issueID: "FEAT-S", branch: stateBranch, repositories: ["backend", "mobile"],
            pushedTips: ["backend": backendTip, "mobile": mobileTip]
        )
        for repository in ["backend", "mobile"] {
            try journal.recordPullRequest(
                featureID: featureID, repository: repository, url: url(repository, 12), nightID: context.night.id,
                runID: runID
            )
        }
        let recordedLanding = String(repeating: "1a", count: 20)
        try journal.recordLanding(
            featureID: featureID, repository: "backend", landingCommit: recordedLanding,
            mainlineCommit: recordedLanding, evidence: .content
        )
        let otherMerge = await headCommit("main", in: backend)
        let read = ScriptedPullRequestRead([
            "backend": .found([observed("backend", 12, state: .merged, mergeCommit: otherMerge, head: backendTip)]),
            "mobile": .found([observed("mobile", 12, state: .open, head: mobileTip)])
        ])

        let outcome = try await PredecessorAncestryGate(publication: read).check(context, unmergedFeaturesMax: 1)

        #expect(singleUnmerged(outcome)?.repositories == ["mobile"])
        #expect(await read.queried("backend").count == 1)
        #expect(try journal.pullRequest(featureID: featureID, repository: "backend")?.observedState == .merged)
        #expect(try journal.pullRequest(featureID: featureID, repository: "mobile")?.observedState == .open)
        #expect(try journal.landingEvidence(featureID: featureID) == ["backend": .content])
        #expect(try journal.landingCommits(featureID: featureID) == ["backend": recordedLanding])
    }

    @Test("Where ancestry records the Observed Merge, the read still records the state and the evidence stays ancestry")
    func ancestryMergeIsStillRead() async throws {
        let repo = GateGitFixture(name: "state-ancestry")
        let tip = try await populateFeature(repo, name: "backend")
        _ = await repo.run(["merge", "--no-ff", "-m", "merge", stateBranch])
        let mergeCommit = await headCommit("main", in: repo)
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let (context, runID) = try makeGateContext(journal, repositories: repositories([("backend", repo.path)]))
        let featureID = try insertGateFeature(
            journal, issueID: "FEAT-S", branch: stateBranch, repositories: ["backend"], pushedTips: ["backend": tip]
        )
        try journal.recordPullRequest(
            featureID: featureID, repository: "backend", url: url("backend", 12), nightID: context.night.id,
            runID: runID
        )
        let read = ScriptedPullRequestRead([
            "backend": .found([observed("backend", 12, state: .merged, mergeCommit: mergeCommit, head: tip)])
        ])

        let outcome = try await PredecessorAncestryGate(publication: read).check(context, unmergedFeaturesMax: 1)

        #expect(outcome == .open)
        #expect(try journal.landingEvidence(featureID: featureID) == ["backend": .ancestry])
        #expect(try journal.pullRequest(featureID: featureID, repository: "backend")?.observedState == .merged)
    }

    @Test("A pull request whose last observed state is merged is not read again")
    func mergedPullRequestIsNotReadAgain() async throws {
        let backend = GateGitFixture(name: "state-stop-backend")
        let mobile = GateGitFixture(name: "state-stop-mobile")
        let backendTip = try await populateFeature(backend, name: "backend")
        let mobileTip = try await populateFeature(mobile, name: "mobile")
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let (context, runID) = try makeGateContext(
            journal, repositories: repositories([("backend", backend.path), ("mobile", mobile.path)])
        )
        let featureID = try insertGateFeature(
            journal, issueID: "FEAT-S", branch: stateBranch, repositories: ["backend", "mobile"],
            pushedTips: ["backend": backendTip, "mobile": mobileTip]
        )
        for repository in ["backend", "mobile"] {
            try journal.recordPullRequest(
                featureID: featureID, repository: repository, url: url(repository, 12), nightID: context.night.id,
                runID: runID
            )
        }
        let landing = String(repeating: "1a", count: 20)
        try journal.recordLanding(
            featureID: featureID, repository: "backend", landingCommit: landing, mainlineCommit: landing,
            evidence: .pullRequest
        )
        try journal.recordObservedPullRequest(
            featureID: featureID, repository: "backend",
            observed: observed("backend", 12, state: .merged, mergeCommit: landing, head: backendTip),
            runID: runID
        )
        let read = ScriptedPullRequestRead([
            "backend": .failed(.unreachable),
            "mobile": .found([observed("mobile", 12, state: .open, head: mobileTip)])
        ])

        _ = try await PredecessorAncestryGate(publication: read).check(context, unmergedFeaturesMax: 1)

        #expect(await read.queried("backend").isEmpty)
        #expect(await read.queried("mobile").count == 1)
        #expect(try readFailures(journal).isEmpty)
    }

    @Test("A Feature that left U is not read")
    func featureThatLeftUIsNotRead() async throws {
        let repo = GateGitFixture(name: "state-left-u")
        let tip = try await populateFeature(repo, name: "backend")
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let (context, runID) = try makeGateContext(journal, repositories: repositories([("backend", repo.path)]))
        let featureID = try insertGateFeature(
            journal, issueID: "FEAT-S", branch: stateBranch, repositories: ["backend"], pushedTips: ["backend": tip]
        )
        try journal.recordPullRequest(
            featureID: featureID, repository: "backend", url: url("backend", 12), nightID: context.night.id,
            runID: runID
        )
        let landing = String(repeating: "1a", count: 20)
        try journal.recordLanding(
            featureID: featureID, repository: "backend", landingCommit: landing, mainlineCommit: landing,
            evidence: .content
        )
        let read = ScriptedPullRequestRead(["backend": .found([observed("backend", 12, state: .open, head: tip)])])

        let outcome = try await PredecessorAncestryGate(publication: read).check(context, unmergedFeaturesMax: 1)

        #expect(outcome == .open)
        #expect(await read.queries.isEmpty)
        #expect(try journal.pullRequest(featureID: featureID, repository: "backend")?.observedState == nil)
    }

    @Test("A pull request read merged into a lower branch is not read again; it passes once its merge reaches mainline")
    func storedMergeIsTestedWithoutAnotherRead() async throws {
        let repo = GateGitFixture(name: "state-lower")
        let tip = try await populateFeature(repo, name: "backend")
        _ = await repo.run(["checkout", "-b", lowerBranch, "main"])
        let lowerMerge = try await repo.commit(filename: "lower.txt", content: "lower\n", message: "merged into lower")
        _ = await repo.run(["checkout", "main"])
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let (context, runID) = try makeGateContext(journal, repositories: repositories([("backend", repo.path)]))
        let featureID = try insertGateFeature(
            journal, issueID: "FEAT-S", branch: stateBranch, repositories: ["backend"], pushedTips: ["backend": tip]
        )
        try journal.recordPullRequest(
            featureID: featureID, repository: "backend", url: url("backend", 12), nightID: context.night.id,
            runID: runID
        )
        let read = ScriptedPullRequestRead([
            "backend": .found([
                observed("backend", 12, state: .merged, mergeCommit: lowerMerge, head: tip, base: lowerBranch)
            ])
        ])
        let gate = PredecessorAncestryGate(publication: read)

        let first = try await gate.check(context, unmergedFeaturesMax: 1)

        #expect(singleUnmerged(first)?.repositories == ["backend"])
        #expect(try journal.landingEvidence(featureID: featureID).isEmpty)
        #expect(try journal.pullRequest(featureID: featureID, repository: "backend")?.mergeCommit == lowerMerge)

        _ = await repo.run(["merge", "--no-ff", "-m", "merge the lower branch", lowerBranch])
        await read.answer("backend", with: .failed(.unreachable))

        let second = try await gate.check(context, unmergedFeaturesMax: 1)

        #expect(second == .open)
        #expect(await read.queried("backend").count == 1)
        #expect(try journal.landingEvidence(featureID: featureID) == ["backend": .pullRequest])
        #expect(try journal.landingCommits(featureID: featureID) == ["backend": lowerMerge])
        #expect(try readFailures(journal).isEmpty)
    }

    @Test("The extra reads append at most one PullRequestReadFailed per repository per pass")
    func oneFailurePerRepositoryWithTheExtraReads() async throws {
        let backend = GateGitFixture(name: "state-fail-backend")
        let mobile = GateGitFixture(name: "state-fail-mobile")
        let backendTip = try await populateFeature(backend, name: "backend")
        let mobileTip = try await populateFeature(mobile, name: "mobile")
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let (context, runID) = try makeGateContext(
            journal, repositories: repositories([("backend", backend.path), ("mobile", mobile.path)])
        )
        let mergedID = try insertGateFeature(
            journal, issueID: "FEAT-S", branch: stateBranch, repositories: ["backend", "mobile"],
            pushedTips: ["backend": backendTip, "mobile": mobileTip]
        )
        let landing = String(repeating: "1a", count: 20)
        try journal.recordLanding(
            featureID: mergedID, repository: "backend", landingCommit: landing, mainlineCommit: landing,
            evidence: .content
        )
        let otherID = try insertGateFeature(
            journal, issueID: "FEAT-T", branch: stateBranch, repositories: ["backend"],
            pushedTips: ["backend": backendTip]
        )
        for (featureID, repository) in [(mergedID, "backend"), (mergedID, "mobile"), (otherID, "backend")] {
            try journal.recordPullRequest(
                featureID: featureID, repository: repository, url: url(repository, 12), nightID: context.night.id,
                runID: runID
            )
        }
        let read = ScriptedPullRequestRead(["backend": .failed(.rateLimited), "mobile": .failed(.rateLimited)])

        _ = try await PredecessorAncestryGate(publication: read).check(context, unmergedFeaturesMax: 3)

        #expect(await read.queried("backend").count == 2)
        #expect(try readFailures(journal) == [
            .pullRequestReadFailed(repository: "backend", reason: .rateLimited),
            .pullRequestReadFailed(repository: "mobile", reason: .rateLimited)
        ])
        #expect(try journal.landingEvidence(featureID: mergedID) == ["backend": .content])
    }
}
