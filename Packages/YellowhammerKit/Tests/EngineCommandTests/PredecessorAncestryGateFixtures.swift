import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
@testable import Journal
import Repositories
import Testing

// roadmap P9.2: the predecessor-ancestry gate. Reads the most recent Feature that is not in flight
// (its Cycle archived), evaluates ancestry for its Feature Branch in the repositories its Cycle
// touched, re-tests merge only for the unmerged ones, and records what it found. Allocates no
// Worktree, dispatches nothing, records no Attempt. Fixtures and helpers, split out of
// PredecessorAncestryGateTests.swift to keep that file under the file length limit.

let gateNightStart = NightStart(rawValue: "2026-09-19")!

/// A tiny throwaway git repository, local to this file — `Tests/RepositoriesTests/GitFixture.swift`
/// is not visible from this test target, so this is the minimal equivalent the brief allows.
struct GateGitFixture: ~Copyable {
    let url: URL
    let git = GitRunner()

    init(name: String = "repo") {
        url = FileManager.default.temporaryDirectory
            .appending(component: "yh-gate-git-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
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

    func initRepo(defaultBranch: String = "main") async {
        _ = await run(["init", "--initial-branch=\(defaultBranch)"])
        _ = await run(["config", "user.name", "Yellowhammer Test"])
        _ = await run(["config", "user.email", "test@yellowhammer.local"])
        _ = await run(["config", "commit.gpgsign", "false"])
    }

    @discardableResult
    func commit(filename: String = "file.txt", content: String = "content", message: String = "commit") async throws
        -> String {
        let fileURL = url.appendingPathComponent(filename)
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        _ = await run(["add", "."])
        _ = await run(["commit", "-m", message])
        let result = await run(["rev-parse", "HEAD"])
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A `PostMergeClosure` that records how many times it was called.
final class ScriptedPostMergeClosure: PostMergeClosure, @unchecked Sendable {
    private(set) var callCount = 0

    func closeByMerge(feature: FeatureRecord, context: ActContext) async throws {
        callCount += 1
    }
}

/// Inserts a Feature and its Cycle, archiving the Cycle unless `inFlight` — the predecessor read only
/// ever picks up an archived (not in-flight) Cycle's Feature. `repositories` is recorded directly into
/// `feature_repository` (roadmap P9.9), the gate's own source of touched repositories — never derived
/// from Cards.
@discardableResult
func insertGateFeature(
    _ journal: JournalStore, issueID: String, branch: String?, repositories: [String] = [],
    inFlight: Bool = false, landed: Bool = false, released: Bool = false
) throws -> Int64 {
    try journal.write { db in
        try db.execute(
            sql: "INSERT INTO feature (issue_id, state, worktree_name, released_at, created_at) VALUES (?, ?, ?, ?, ?)",
            arguments: [
                issueID, "selected", branch, released ? JournalStore.timestamp(outboxEpoch) : nil,
                JournalStore.timestamp(outboxEpoch)
            ]
        )
        let featureID = db.lastInsertedRowID
        try db.execute(
            sql: "INSERT INTO cycle (feature_id, created_at, archived_at, landed_at) VALUES (?, ?, ?, ?)",
            arguments: [
                featureID, JournalStore.timestamp(outboxEpoch),
                inFlight ? nil : JournalStore.timestamp(outboxEpoch),
                landed ? JournalStore.timestamp(outboxEpoch) : nil
            ]
        )
        for repository in repositories {
            try db.execute(
                sql: "INSERT INTO feature_repository (feature_id, repository) VALUES (?, ?)",
                arguments: [featureID, repository]
            )
        }
        return featureID
    }
}

func gateCycleID(_ journal: JournalStore, featureID: Int64) throws -> Int64 {
    try journal.write { db in
        try Int64.fetchOne(db, sql: "SELECT id FROM cycle WHERE feature_id = ?", arguments: [featureID])!
    }
}

@discardableResult
func insertGateCard(_ journal: JournalStore, cycleID: Int64, issueID: String, repository: String) throws
    -> Int64 {
    try journal.write { db in
        let nextOrder = try Int.fetchOne(
            db,
            sql: "SELECT COALESCE(MAX(authored_order), 0) + 1 FROM card WHERE cycle_id = ? AND repository = ?",
            arguments: [cycleID, repository]
        ) ?? 1
        try db.execute(
            sql: """
            INSERT INTO card (cycle_id, issue_id, repository, kind, authored_order, state, budget_epoch, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                cycleID, issueID, repository, "card", nextOrder, CardState.todo.rawValue, 0,
                JournalStore.timestamp(outboxEpoch)
            ]
        )
        return db.lastInsertedRowID
    }
}

/// Claims the Act lease, opens a Night, and builds the `ActContext` the gate is handed —
/// `ReadinessCheckTests.directEvaluate`'s pattern for calling an Engine-level check directly against
/// a Journal fixture, without an `EngineInvocation` in the way.
func makeGateContext(
    _ journal: JournalStore, repositories: ProjectRepositories?
) throws -> (context: ActContext, runID: RunID) {
    let runID = RunID()
    guard case .claimed = try journal.claimActLease(act: .author, runID: runID, mode: .rehearsal) else {
        throw JournalError.actLeaseLost(runID: runID, holder: nil)
    }
    let opening = try journal.openNight(nightStart: gateNightStart, mode: .rehearsal, act: .author, runID: runID)
    let context = ActContext(
        act: .author, mode: .rehearsal, trigger: .scheduled, runID: runID, journal: journal,
        night: opening.night, repositories: repositories
    )
    return (context, runID)
}
