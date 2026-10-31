import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
@testable import Journal
import Repositories
import Testing

// feature-authoring/select-the-next-feature #merge-test, #net-zero-branch and the criterion "Predecessor tracking
// across the unmerged Feature stack" ("Missing merge proof remains indeterminate"); OQ190 items 22 and 26. A tip that
// is an ancestor of mainline, but whose landing commit git cannot read, has no Observed Merge by ancestry: the record
// carries the landing commit. It still goes to the pull request test, but never to the content test, which cannot
// hold for an ancestor (its fork point is the tip itself). Where the pull request does not show the merge, the
// repository is indeterminate for the pass, not unmerged. Real git, local only; the landing-commit read is made to
// fail by a wrapping `git`, and the pull request read is a fake Port.

private let landingBranch = "yh-landing-feature"
private let landingURL = "https://github.com/o/backend/pull/31"

/// A `git` that logs each invocation's arguments, then runs the real git, except that the first-parent chain read
/// `AncestryTester.landingCommit(of:mainline:in:)` makes exits 128, as a lock or an I/O error would.
private struct LandingReadFailingGit: ~Copyable {
    let directory: URL
    let runner: GitRunner

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(component: "landing-failing-git-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let log = directory.appending(component: "argv").path(percentEncoded: false)
        let script = """
            #!/bin/sh
            printf '%s\\n' "$*" >> '\(log)'
            case "$*" in *'rev-list --first-parent --reverse'*) exit 128 ;; esac
            exec '\(GitRunner.findGitExecutable())' "$@"

            """
        let git = directory.appending(component: "git")
        try Data(script.utf8).write(to: git)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: git.path)
        runner = GitRunner(executablePath: git.path(percentEncoded: false))
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    var invocations: [String] {
        let text = (try? String(contentsOf: directory.appending(component: "argv"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init)
    }
}

/// A Publication Port fixture that answers every pull request read with the same pull requests.
private actor FixedPullRequestRead: Publication {
    private let pullRequests: [ObservedPullRequest]

    init(_ pullRequests: [ObservedPullRequest]) {
        self.pullRequests = pullRequests
    }

    func openPullRequest(_ draft: PullRequestDraft) async throws(PublicationError) -> PullRequestReceipt {
        throw .other("the predecessor gate never opens a pull request")
    }

    func readPullRequests(_ query: PullRequestQuery) async throws(PullRequestReadFailure) -> [ObservedPullRequest] {
        pullRequests
    }
}

/// A repository whose GitHub `origin` is `o/backend` (never fetched), with `yh-landing-feature` merged into `main`
/// by a merge commit, so the Pushed Tip is an ancestor of mainline but not mainline itself. Returns the Pushed Tip
/// and the merge commit.
private func populateMergedFeature(_ repo: borrowing GateGitFixture) async throws -> (tip: String, merge: String) {
    await repo.initRepo()
    _ = await repo.run(["remote", "add", "origin", "https://github.com/o/backend.git"])
    _ = try await repo.commit(filename: "shared.txt", content: "base\n", message: "init")
    _ = await repo.run(["checkout", "-b", landingBranch])
    let tip = try await repo.commit(filename: "feat.txt", content: "feature\n", message: "add feat")
    _ = await repo.run(["checkout", "main"])
    _ = await repo.run(["merge", "--no-ff", "-m", "merge \(landingBranch)", landingBranch])
    let merge = await repo.run(["rev-parse", "main"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    return (tip, merge)
}

private func gate(git: borrowing LandingReadFailingGit, publication: any Publication) -> PredecessorAncestryGate {
    PredecessorAncestryGate(
        ancestryTester: AncestryTester(git: git.runner), mergeTester: MergeTester(git: git.runner),
        publication: publication
    )
}

@Suite("Predecessor gate: an ancestor whose landing commit cannot be read (OQ190 items 22, 26)")
struct PredecessorGateLandingCommitTests {
    @Test("an ancestor whose pull request reads open is indeterminate, never unmerged, and skips the content test")
    func unreadableLandingCommitIsIndeterminate() async throws {
        let repo = GateGitFixture(name: "landing-unreadable")
        let (tip, _) = try await populateMergedFeature(repo)
        let git = try LandingReadFailingGit()
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let repositories = ProjectRepositories(
            workingRepos: [Repo(name: "backend", path: repo.path, role: .backend)]
        )
        let (context, runID) = try makeGateContext(journal, repositories: repositories)
        let featureID = try insertGateFeature(
            journal, issueID: "FEAT-LC", branch: landingBranch, repositories: ["backend"],
            pushedTips: ["backend": tip]
        )
        try journal.recordPullRequest(
            featureID: featureID, repository: "backend", url: landingURL, nightID: context.night.id, runID: runID
        )
        let read = FixedPullRequestRead([
            ObservedPullRequest(
                number: 31, url: landingURL, state: .open, mergeCommit: nil, headCommit: tip,
                headBranch: landingBranch, baseBranch: "main"
            )
        ])

        let outcome = try await gate(git: git, publication: read).check(context, unmergedFeaturesMax: 1)

        #expect(outcome == .indeterminate(predecessorIssueID: "FEAT-LC", repositories: ["backend"]))
        #expect(try journal.landings(featureID: featureID).isEmpty)
        #expect(try journal.events(ofType: .mainlineConflictDetected).isEmpty)
        let invocations = git.invocations
        #expect(invocations.contains { $0.contains("rev-list --first-parent --reverse") })
        #expect(!invocations.contains { $0.contains(" merge-tree ") })
    }

    @Test("an ancestor whose landing commit cannot be read is still observed by its merged pull request")
    func mergedPullRequestStillRecordsTheMerge() async throws {
        let repo = GateGitFixture(name: "landing-unreadable-pr")
        let (tip, merge) = try await populateMergedFeature(repo)
        let git = try LandingReadFailingGit()
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let repositories = ProjectRepositories(
            workingRepos: [Repo(name: "backend", path: repo.path, role: .backend)]
        )
        let (context, runID) = try makeGateContext(journal, repositories: repositories)
        let featureID = try insertGateFeature(
            journal, issueID: "FEAT-LC", branch: landingBranch, repositories: ["backend"],
            pushedTips: ["backend": tip]
        )
        try journal.recordPullRequest(
            featureID: featureID, repository: "backend", url: landingURL, nightID: context.night.id, runID: runID
        )
        let read = FixedPullRequestRead([
            ObservedPullRequest(
                number: 31, url: landingURL, state: .merged, mergeCommit: merge, headCommit: tip,
                headBranch: landingBranch, baseBranch: "main"
            )
        ])

        let outcome = try await gate(git: git, publication: read).check(context, unmergedFeaturesMax: 1)

        #expect(outcome == .open)
        #expect(try journal.landingEvidence(featureID: featureID) == ["backend": .pullRequest])
        #expect(try journal.landingCommits(featureID: featureID) == ["backend": merge])
    }
}
