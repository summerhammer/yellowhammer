import Domain
@testable import Engine
import Foundation
@testable import Journal
import Repositories
import Testing

/// A Feature → Cycle with one Work Card per repository (`backend`, and `mobile` when asked), real git per
/// repository (see `OQ191LandWorld.swift`), clauses to verify, a `feature_base` row per repository at its
/// `main`, and a held Worktree per repository under one layout directory. Each ``fire(verifier:)`` is one land
/// firing on the same Journal, Outbox and board, with the real push and pull request seams, real
/// ``FeatureVerification`` over a scripted verifier, and a fake Workspace for release.
final class OQ191LandWorld {
    let env: Environment
    /// The parent directory of every held Worktree.
    let layout: TestGitRepo
    let repositories: [OQ191Repository]
    let feature: FeatureRecord
    let cycleID: Int64
    let log = LandCallLog()
    let publication: OQ191Publication
    let workspace: ReconcilerFakeWorkspace
    private let slugResolver: GitHubRepositorySlugResolver

    private init(
        env: Environment, layout: TestGitRepo, repositories: [OQ191Repository], feature: FeatureRecord,
        cycleID: Int64, publication: OQ191Publication, workspace: ReconcilerFakeWorkspace
    ) {
        self.env = env
        self.layout = layout
        self.repositories = repositories
        self.feature = feature
        self.cycleID = cycleID
        self.publication = publication
        self.workspace = workspace
        // Only the slug read sees a GitHub URL for each bare remote; every other git call reaches the remote.
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_COUNT"] = String(repositories.count)
        for (index, repository) in repositories.enumerated() {
            environment["GIT_CONFIG_KEY_\(index)"] = "url.git@github.com:summerhammer/\(repository.name).git.insteadOf"
            environment["GIT_CONFIG_VALUE_\(index)"] = repository.remote.path
        }
        slugResolver = GitHubRepositorySlugResolver(git: GitRunner(environment: environment))
    }

    subscript(_ name: String) -> OQ191Repository {
        guard let repository = repositories.first(where: { $0.name == name }) else {
            preconditionFailure("the OQ191 world has no repository \(name)")
        }
        return repository
    }

    /// `withMobile` adds the `mobile` repository beside `backend`. A repository in `noPushedBranch` has no commit
    /// past its base (the No-Pushed-Branch Outcome). A repository in `refusingPullRequest` has its first pull
    /// request refused by the Publication fixture.
    static func make(
        withMobile: Bool = true, noPushedBranch: Set<String> = [], refusingPullRequest: Set<String> = []
    ) async throws -> OQ191LandWorld {
        let layout = TestGitRepo(name: "oq191-layout")
        var repositories: [OQ191Repository] = []
        for name in withMobile ? ["backend", "mobile"] : ["backend"] {
            repositories.append(
                try await makeRepository(name, layout: layout, noPushedBranch: noPushedBranch.contains(name))
            )
        }
        let workspace = ReconcilerFakeWorkspace()
        let env = try await Environment.make(
            repos: repositories.map { Repo(name: $0.name, path: $0.clone.path, role: .backend, defaultBranch: "main") },
            workspace: workspace, specSource: SpecSource(path: "/repos/spec")
        )
        for issue in ["FEAT-1", "BACK-1", "MOB-1"] {
            await env.board.seed(issue: issue, description: nil)
        }
        let (feature, cycleID) = try env.setUpFeature(secondRepository: withMobile ? "mobile" : nil)
        try record(repositories, feature: feature, env: env)
        let publication = OQ191Publication(
            refusing: refusingPullRequest,
            remotePaths: Dictionary(uniqueKeysWithValues: repositories.map { ($0.name, $0.remote.path) })
        )
        return OQ191LandWorld(
            env: env, layout: layout, repositories: repositories, feature: feature, cycleID: cycleID,
            publication: publication, workspace: workspace
        )
    }

    private static func makeRepository(
        _ name: String, layout: TestGitRepo, noPushedBranch: Bool
    ) async throws -> OQ191Repository {
        let clone = TestGitRepo(name: "oq191-\(name)-clone")
        await clone.initRepo(defaultBranch: "main")
        let base = try await clone.commit(filename: "README.md", content: name, message: "initial")
        let remote = TestGitRepo(name: "oq191-\(name)-remote")
        await remote.initRepo(bare: true, defaultBranch: "main")
        await clone.addRemote(url: remote.path)
        #expect(await clone.run(["push", "origin", "main"]).isSuccess)
        let worktree = layout.url.appending(component: name, directoryHint: .isDirectory).path(percentEncoded: false)
        #expect(await clone.run(["worktree", "add", "-b", landBranch.name, worktree]).isSuccess)
        let repository = OQ191Repository(
            name: name, clone: clone, remote: remote, worktree: worktree, base: base, tip: base
        )
        guard !noPushedBranch else { return repository }
        let tip = try await repository.commitInWorktree("\(name)-work.txt")
        return OQ191Repository(name: name, clone: clone, remote: remote, worktree: worktree, base: base, tip: tip)
    }

    /// What authoring and the build Act would have recorded: touched repositories, bases, clauses, held Worktrees.
    private static func record(_ repositories: [OQ191Repository], feature: FeatureRecord, env: Environment) throws {
        let journal = env.journal
        try recordTouchedRepositories(journal, featureID: feature.id, repositories: repositories.map(\.name))
        try journal.recordFeatureBases(featureID: feature.id, bases: repositories.map {
            FeatureBaseRecord(repository: $0.name, baseRef: "refs/remotes/origin/main", baseCommit: $0.base)
        })
        for repository in repositories {
            let issue = repository.name == "backend" ? "BACK-1" : "MOB-1"
            try journal.insertClause(JournalStore.NewClause(
                cid: "c1", issueID: issue, level: "card", text: "Clause c1 of \(issue).",
                locationID: "resolvable/story", provenance: "machine-found", citationProvenance: "machine-found"
            ))
            try env.recordHeldWorktree(
                featureID: feature.id, repository: repository.name, worktreeID: "wt-\(repository.name)",
                path: repository.worktree
            )
        }
    }

    /// One land firing. `verifier` scripts the verifier's answer; `.refuse` leaves no Route, so Verification
    /// faults.
    @discardableResult
    func fire(verifier: VerifierBehaviour = .judgeAll()) async -> OQ191Firing {
        let dispatch = ScriptedVerifierDispatch([routeOther: verifier])
        let act = LandAct(
            mergeTest: StubMergeTest(log: log),
            push: OQ191LoggedPush(inner: FeatureBranchLanePush(credential: { nil }), log: log),
            openPullRequest: FeatureBranchPullRequest(
                publication: publication, slugResolver: slugResolver, clock: { landEpoch }
            ),
            verification: FeatureVerification(
                resolver: verificationResolver(primary: routeOther), dispatch: dispatch,
                citations: FakeCitationResolver()
            ),
            returnFeature: StubReturnFeature(log: log),
            archiveCycle: StubArchiveCycle(log: log)
        )
        do {
            try await act.run(env.context)
            return OQ191Firing(dispatch: dispatch, error: nil)
        } catch {
            return OQ191Firing(dispatch: dispatch, error: error)
        }
    }

    /// How many times the push seam was called for `repository`, over every firing.
    func pushCalls(_ repository: String) -> Int {
        log.all.filter { $0 == "push:\(repository)" }.count
    }

    var isCycleLanded: Bool {
        get throws { try env.journal.isCycleLanded(cycleID: cycleID) }
    }

    func unpublishedReports(_ repository: String) async throws -> [String]? {
        try await OQ191Probe.unpublishedCommitsReports(env.journal, board: env.board, repository: repository)
    }

    func remoteTipFailures(_ repository: String) async throws -> [String]? {
        try await OQ191Probe.remoteTipFailures(env.journal, board: env.board, repository: repository)
    }
}
