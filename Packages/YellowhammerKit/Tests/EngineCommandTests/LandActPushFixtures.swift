import Domain
@testable import Engine
import Foundation
@testable import Journal
import Repositories
import Testing

// Shared fixtures for LandActPushTests and LandActPushTests+Worktrees.

/// Minimal git fixture for these tests — `Tests/RepositoriesTests/GitFixture.swift` lives in a
/// different test target and is not visible here.
final class TestGitRepo {
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
final class LandPushTestEnvironment {
    private let directory: URL
    let journal: JournalStore
    let board: FakeWritingBoard
    let runID: RunID
    let workspace: ReconcilerFakeWorkspace?
    let context: ActContext

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private init(
        directory: URL,
        journal: JournalStore,
        board: FakeWritingBoard,
        runID: RunID,
        workspace: ReconcilerFakeWorkspace?,
        context: ActContext
    ) {
        self.directory = directory
        self.journal = journal
        self.board = board
        self.runID = runID
        self.workspace = workspace
        self.context = context
    }

    static func make(repos: [Repo], workspace: ReconcilerFakeWorkspace? = nil) async throws -> LandPushTestEnvironment {
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
            outbox: outbox, mainlines: ResolvedMainlines(), workspace: workspace,
            repositories: ProjectRepositories(workingRepos: repos)
        )
        return LandPushTestEnvironment(
            directory: directory, journal: journal, board: board, runID: runID, workspace: workspace, context: context
        )
    }

    /// Records a Feature → Cycle → one or two Cards (`.done`) and the Feature Branch.
    /// `secondRepository`, when given, adds a second lane's Card. Returns the resulting Feature record
    /// and its Cycle id, read back through `inFlightFeature()`.
    func setUpFeature(
        branch: FeatureBranch = landBranch, secondRepository: String? = nil, firstCardTitle: String? = nil
    ) throws -> (feature: FeatureRecord, cycleID: Int64) {
        let featureID = try insertReconcilerFeature(journal, issueID: "FEAT-1")
        try journal.recordFeatureBranch(featureID: featureID, branch: branch)
        let cycleID = try insertReconcilerCycle(journal, featureID: featureID)
        try insertReconcilerCard(
            journal, cycleID: cycleID, issueID: "BACK-1", repository: "backend", state: .done, title: firstCardTitle
        )
        if let secondRepository {
            try insertReconcilerCard(
                journal, cycleID: cycleID, issueID: "MOB-1", repository: secondRepository, state: .done
            )
        }
        return try #require(try journal.inFlightFeature())
    }

    @discardableResult
    func recordHeldWorktree(
        featureID: Int64, repository: String, worktreeID: String = "wt-backend", path: String = "/tmp/wt"
    ) throws -> WorktreeRecord {
        try journal.recordWorktree(
            featureID: featureID,
            repository: repository,
            worktreeID: worktreeID,
            path: path,
            runID: runID
        )
    }

    func pushStep(repository: String) -> (outcome: LandStepOutcome, detail: String?)? {
        guard let record = try? journal.events(ofType: .landStep).last(where: { record in
            guard case .landStep(let step, let repo, _, _) = record.event else { return false }
            return step == .push && repo == repository
        }) else { return nil }
        guard case .landStep(_, _, let outcome, let detail) = record.event else { return nil }
        return (outcome, detail)
    }

    func releaseWorktreeStep(repository: String) -> (outcome: LandStepOutcome, detail: String?)? {
        guard let record = try? journal.events(ofType: .landStep).last(where: { record in
            guard case .landStep(let step, let repo, _, _) = record.event else { return false }
            return step == .releaseWorktree && repo == repository
        }) else { return nil }
        guard case .landStep(_, _, let outcome, let detail) = record.event else { return nil }
        return (outcome, detail)
    }
}

typealias Environment = LandPushTestEnvironment
