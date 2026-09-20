import Domain
@testable import Engine
import Foundation
@testable import Journal
import Repositories
import Testing

// roadmap P10.2: the land Act's Repo Lane push, through the real ``FeatureBranchLanePush`` seam.
// Exercises ``LandAct/run(lane:feature:cycleID:context:)`` directly (rather than the full
// `EngineInvocation`, which would also require a real Board Port for the Night Card) against real
// fixture git repositories with local bare remotes, mirroring `FeatureBranchPusherTests`.

@Suite("Land Act push (P10.2)")
struct LandActPushTests {
    @Test("A pushed Feature Branch lands the tip on the remote, records the push, and comments on each done Card")
    func pushedRecordsAndComments() async throws {
        let local = TestGitRepo(name: "push-ok-local")
        await local.initRepo(defaultBranch: "main")
        _ = try await local.commit(message: "initial")
        _ = await local.run(["checkout", "-b", "yh-proj-feat"])
        let featureSHA = try await local.commit(filename: "feat.txt", content: "feature", message: "feature work")

        let remote = TestGitRepo(name: "push-ok-remote")
        await remote.initRepo(bare: true, defaultBranch: "main")
        await local.addRemote(url: remote.path)

        let repo = Repo(name: "backend", path: local.path, role: .backend, defaultBranch: "main")
        let env = try await Environment.make(repos: [repo])
        await env.board.seed(issue: "BACK-1", description: nil)
        let (feature, cycleID) = try env.setUpFeature()

        let land = LandAct(push: FeatureBranchLanePush(token: { nil }))
        let failure = await land.run(
            lane: RepoLane(repository: "backend", cards: try env.journal.cards(cycleID: cycleID)),
            feature: feature, cycleID: cycleID, context: env.context
        )
        #expect(failure == nil)

        let step = try #require(env.pushStep(repository: "backend"))
        #expect(step.outcome == .completed)
        #expect(step.detail == featureSHA)
        await #expect(remote.revParse("refs/heads/yh-proj-feat") == featureSHA)

        let comments = await env.board.comments
        #expect(comments.contains { $0.issue.rawValue == "BACK-1" && $0.body.contains(featureSHA) })
    }

    @Test("A Feature Branch that does not exist in the repository is no completed work; nothing is pushed")
    func noCompletedWorkBranchAbsent() async throws {
        let local = TestGitRepo(name: "push-absent-local")
        await local.initRepo(defaultBranch: "main")
        _ = try await local.commit(message: "initial")

        let remote = TestGitRepo(name: "push-absent-remote")
        await remote.initRepo(bare: true, defaultBranch: "main")
        await local.addRemote(url: remote.path)

        let repo = Repo(name: "backend", path: local.path, role: .backend, defaultBranch: "main")
        let env = try await Environment.make(repos: [repo])
        await env.board.seed(issue: "FEAT-1", description: nil)
        let (feature, cycleID) = try env.setUpFeature()

        let land = LandAct(push: FeatureBranchLanePush(token: { nil }))
        let failure = await land.run(
            lane: RepoLane(repository: "backend", cards: try env.journal.cards(cycleID: cycleID)),
            feature: feature, cycleID: cycleID, context: env.context
        )
        #expect(failure == nil)

        let step = try #require(env.pushStep(repository: "backend"))
        #expect(step.outcome == .skipped)
        await #expect(remote.revParse("refs/heads/yh-proj-feat") == nil)
        let comments = await env.board.comments
        #expect(comments.isEmpty)
    }

    @Test("A Feature Branch with no commits ahead of Mainline is no completed work; nothing is pushed")
    func noCompletedWorkZeroCommitsAhead() async throws {
        let local = TestGitRepo(name: "push-zero-local")
        await local.initRepo(defaultBranch: "main")
        _ = try await local.commit(message: "initial")
        _ = await local.run(["checkout", "-b", "yh-proj-feat"])

        let remote = TestGitRepo(name: "push-zero-remote")
        await remote.initRepo(bare: true, defaultBranch: "main")
        await local.addRemote(url: remote.path)

        let repo = Repo(name: "backend", path: local.path, role: .backend, defaultBranch: "main")
        let env = try await Environment.make(repos: [repo])
        let (feature, cycleID) = try env.setUpFeature()

        let land = LandAct(push: FeatureBranchLanePush(token: { nil }))
        let failure = await land.run(
            lane: RepoLane(repository: "backend", cards: try env.journal.cards(cycleID: cycleID)),
            feature: feature, cycleID: cycleID, context: env.context
        )
        #expect(failure == nil)

        let step = try #require(env.pushStep(repository: "backend"))
        #expect(step.outcome == .skipped)
        await #expect(remote.revParse("refs/heads/yh-proj-feat") == nil)
    }

    @Test("Branch protection on the remote records a failed step and comments on the Feature Issue")
    func branchProtectionRefusal() async throws {
        let local = TestGitRepo(name: "push-protected-local")
        await local.initRepo(defaultBranch: "main")
        _ = try await local.commit(message: "initial")
        _ = await local.run(["checkout", "-b", "yh-proj-feat"])
        _ = try await local.commit(filename: "feat.txt", content: "feature", message: "feature work")

        let remote = TestGitRepo(name: "push-protected-remote")
        await remote.initRepo(bare: true, defaultBranch: "main")
        try remote.installHook(
            named: "pre-receive",
            script: """
            #!/bin/sh
            echo "GH006: Protected branch update failed" 1>&2
            exit 1
            """
        )
        await local.addRemote(url: remote.path)

        let repo = Repo(name: "backend", path: local.path, role: .backend, defaultBranch: "main")
        let env = try await Environment.make(repos: [repo])
        await env.board.seed(issue: "FEAT-1", description: nil)
        let (feature, cycleID) = try env.setUpFeature()

        let land = LandAct(push: FeatureBranchLanePush(token: { nil }))
        let failure = await land.run(
            lane: RepoLane(repository: "backend", cards: try env.journal.cards(cycleID: cycleID)),
            feature: feature, cycleID: cycleID, context: env.context
        )
        #expect(failure == nil)

        let step = try #require(env.pushStep(repository: "backend"))
        #expect(step.outcome == .failed)
        await #expect(remote.revParse("refs/heads/yh-proj-feat") == nil)

        let comments = await env.board.comments
        #expect(comments.contains {
            $0.issue.rawValue == "FEAT-1" && $0.body.contains("backend") && $0.body.contains("yh-proj-feat")
                && $0.body.contains("branch protection")
        })
    }

    @Test("A token closure that throws is reported as missing credentials; the remote is never touched")
    func credentialsMissing() async throws {
        let local = TestGitRepo(name: "push-creds-local")
        await local.initRepo(defaultBranch: "main")
        _ = try await local.commit(message: "initial")
        _ = await local.run(["checkout", "-b", "yh-proj-feat"])
        _ = try await local.commit(filename: "feat.txt", content: "feature", message: "feature work")

        let remote = TestGitRepo(name: "push-creds-remote")
        await remote.initRepo(bare: true, defaultBranch: "main")
        await local.addRemote(url: remote.path)

        let repo = Repo(name: "backend", path: local.path, role: .backend, defaultBranch: "main")
        let env = try await Environment.make(repos: [repo])
        await env.board.seed(issue: "FEAT-1", description: nil)
        let (feature, cycleID) = try env.setUpFeature()

        struct TokenError: Error {}
        let land = LandAct(push: FeatureBranchLanePush(token: { throw TokenError() }))
        let failure = await land.run(
            lane: RepoLane(repository: "backend", cards: try env.journal.cards(cycleID: cycleID)),
            feature: feature, cycleID: cycleID, context: env.context
        )
        #expect(failure == nil)

        let step = try #require(env.pushStep(repository: "backend"))
        #expect(step.outcome == .failed)
        await #expect(remote.revParse("refs/heads/yh-proj-feat") == nil)

        let comments = await env.board.comments
        #expect(comments.contains { $0.issue.rawValue == "FEAT-1" && $0.body.contains("credentials") })
    }

    @Test("A Feature Branch equal to the default branch refuses as Mainline; the remote main is unchanged")
    func mainlineRefused() async throws {
        let local = TestGitRepo(name: "push-mainline-local")
        await local.initRepo(defaultBranch: "main")
        _ = try await local.commit(message: "initial")

        let remote = TestGitRepo(name: "push-mainline-remote")
        await remote.initRepo(bare: true, defaultBranch: "main")
        await local.addRemote(url: remote.path)

        let repo = Repo(name: "backend", path: local.path, role: .backend, defaultBranch: "main")
        let env = try await Environment.make(repos: [repo])
        await env.board.seed(issue: "FEAT-1", description: nil)
        let (feature, cycleID) = try env.setUpFeature(branch: FeatureBranch(rawValue: "main"))

        let land = LandAct(push: FeatureBranchLanePush(token: { nil }))
        let failure = await land.run(
            lane: RepoLane(repository: "backend", cards: try env.journal.cards(cycleID: cycleID)),
            feature: feature, cycleID: cycleID, context: env.context
        )
        #expect(failure == nil)

        let step = try #require(env.pushStep(repository: "backend"))
        #expect(step.outcome == .failed)
        await #expect(remote.revParse("refs/heads/main") == nil)
    }

    @Test("One lane's push failure does not stop another lane from running")
    func otherLaneStillRuns() async throws {
        let backendLocal = TestGitRepo(name: "push-multi-backend-local")
        await backendLocal.initRepo(defaultBranch: "main")
        _ = try await backendLocal.commit(message: "initial")
        _ = await backendLocal.run(["checkout", "-b", "yh-proj-feat"])
        _ = try await backendLocal.commit(filename: "feat.txt", content: "feature", message: "feature work")
        let backendRemote = TestGitRepo(name: "push-multi-backend-remote")
        await backendRemote.initRepo(bare: true, defaultBranch: "main")
        try backendRemote.installHook(
            named: "pre-receive",
            script: """
            #!/bin/sh
            echo "GH006: Protected branch update failed" 1>&2
            exit 1
            """
        )
        await backendLocal.addRemote(url: backendRemote.path)

        let mobileLocal = TestGitRepo(name: "push-multi-mobile-local")
        await mobileLocal.initRepo(defaultBranch: "main")
        _ = try await mobileLocal.commit(message: "initial")
        _ = await mobileLocal.run(["checkout", "-b", "yh-proj-feat"])
        let mobileSHA = try await mobileLocal.commit(
            filename: "feat.txt", content: "feature", message: "feature work"
        )
        let mobileRemote = TestGitRepo(name: "push-multi-mobile-remote")
        await mobileRemote.initRepo(bare: true, defaultBranch: "main")
        await mobileLocal.addRemote(url: mobileRemote.path)

        let backendRepo = Repo(name: "backend", path: backendLocal.path, role: .backend, defaultBranch: "main")
        let mobileRepo = Repo(name: "mobile", path: mobileLocal.path, role: .backend, defaultBranch: "main")
        let env = try await Environment.make(repos: [backendRepo, mobileRepo])
        await env.board.seed(issue: "FEAT-1", description: nil)
        await env.board.seed(issue: "MOB-1", description: nil)
        let (feature, cycleID) = try env.setUpFeature(secondRepository: "mobile")

        let land = LandAct(push: FeatureBranchLanePush(token: { nil }))
        let cards = try env.journal.cards(cycleID: cycleID)
        let backendFailure = await land.run(
            lane: RepoLane(repository: "backend", cards: cards.filter { $0.repository == "backend" }),
            feature: feature, cycleID: cycleID, context: env.context
        )
        let mobileFailure = await land.run(
            lane: RepoLane(repository: "mobile", cards: cards.filter { $0.repository == "mobile" }),
            feature: feature, cycleID: cycleID, context: env.context
        )
        #expect(backendFailure == nil)
        #expect(mobileFailure == nil)

        let backendStep = try #require(env.pushStep(repository: "backend"))
        #expect(backendStep.outcome == .failed)
        let mobileStep = try #require(env.pushStep(repository: "mobile"))
        #expect(mobileStep.outcome == .completed)
        #expect(mobileStep.detail == mobileSHA)
        await #expect(mobileRemote.revParse("refs/heads/yh-proj-feat") == mobileSHA)
    }
}

/// Minimal git fixture for these tests — `Tests/RepositoriesTests/GitFixture.swift` lives in a
/// different test target and is not visible here.
private final class TestGitRepo {
    let url: URL
    let git = GitRunner()

    init(name: String) {
        url = FileManager.default.temporaryDirectory
            .appending(component: "land-push-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    var path: String { url.path(percentEncoded: false) }

    @discardableResult
    func run(_ args: [String]) async -> GitCommandResult {
        await git.run(["-C", path] + args)
    }

    func initRepo(bare: Bool = false, defaultBranch: String = "main") async {
        if bare {
            _ = await run(["init", "--bare", "--initial-branch=\(defaultBranch)"])
        } else {
            _ = await run(["init", "--initial-branch=\(defaultBranch)"])
            _ = await run(["config", "user.name", "Yellowhammer Test"])
            _ = await run(["config", "user.email", "test@yellowhammer.local"])
            _ = await run(["config", "commit.gpgsign", "false"])
        }
    }

    @discardableResult
    func commit(
        filename: String = "file.txt", content: String = "content", message: String = "commit"
    ) async throws -> String {
        let fileURL = url.appendingPathComponent(filename)
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        _ = await run(["add", "."])
        _ = await run(["commit", "-m", message])
        return try #require(await revParse("HEAD"))
    }

    func addRemote(name: String = "origin", url remoteURL: String) async {
        _ = await run(["remote", "add", name, remoteURL])
    }

    func revParse(_ ref: String) async -> String? {
        let result = await run(["rev-parse", "--verify", "--quiet", ref])
        guard result.isSuccess else { return nil }
        let sha = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
    }

    func installHook(named name: String, script: String) throws {
        let hookURL = url.appendingPathComponent("hooks").appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: hookURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try script.write(to: hookURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookURL.path)
    }
}

/// Journal, Outbox and `ActContext` plumbing shared by ``LandActPushTests``: bypasses the full
/// `EngineInvocation` (which would also need a real Board Port for the Night Card) and calls
/// `LandAct.run(lane:feature:cycleID:context:)` directly, as `LandActFixtures.swift` already does for
/// `LandActTests`. Owns its own temp Journal directory, removed in `deinit`.
private final class Environment {
    private let directory: URL
    let journal: JournalStore
    let board: FakeWritingBoard
    let runID: RunID
    let context: ActContext

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private init(directory: URL, journal: JournalStore, board: FakeWritingBoard, runID: RunID, context: ActContext) {
        self.directory = directory
        self.journal = journal
        self.board = board
        self.runID = runID
        self.context = context
    }

    static func make(repos: [Repo]) async throws -> Environment {
        let directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-land-push-\(UUID().uuidString)", directoryHint: .isDirectory)
        let projectID = try #require(ProjectID(rawValue: "fixture"))
        let journal = try JournalStore.openSeeded(configurationDirectory: directory, projectID: projectID)
        let runID = RunID()
        try claimLandLease(journal, runID: runID)
        let night = try journal.openNight(nightStart: landNightStart, mode: .real, act: .land, runID: runID).night
        let board = FakeWritingBoard()
        let outbox = Outbox(journal: journal, board: board, runID: runID, act: .land, clock: { landEpoch })
        let context = ActContext(
            act: .land, mode: .real, trigger: .scheduled, runID: runID, journal: journal, night: night,
            outbox: outbox, mainlines: ResolvedMainlines(), repositories: ProjectRepositories(workingRepos: repos)
        )
        return Environment(directory: directory, journal: journal, board: board, runID: runID, context: context)
    }

    /// Records a Feature → Cycle → one or two Cards (`.done`) and the Feature Branch.
    /// `secondRepository`, when given, adds a second lane's Card. Returns the resulting Feature record
    /// and its Cycle id, read back through `inFlightFeature()`.
    func setUpFeature(
        branch: FeatureBranch = landBranch, secondRepository: String? = nil
    ) throws -> (feature: FeatureRecord, cycleID: Int64) {
        let featureID = try insertReconcilerFeature(journal, issueID: "FEAT-1")
        try journal.recordFeatureBranch(featureID: featureID, branch: branch)
        let cycleID = try insertReconcilerCycle(journal, featureID: featureID)
        try insertReconcilerCard(journal, cycleID: cycleID, issueID: "BACK-1", repository: "backend", state: .done)
        if let secondRepository {
            try insertReconcilerCard(
                journal, cycleID: cycleID, issueID: "MOB-1", repository: secondRepository, state: .done
            )
        }
        return try #require(try journal.inFlightFeature())
    }

    func pushStep(repository: String) -> (outcome: LandStepOutcome, detail: String?)? {
        guard let record = try? journal.events(ofType: .landStep).last(where: { record in
            guard case .landStep(let step, let repo, _, _) = record.event else { return false }
            return step == .push && repo == repository
        }) else { return nil }
        guard case .landStep(_, _, let outcome, let detail) = record.event else { return nil }
        return (outcome, detail)
    }
}
