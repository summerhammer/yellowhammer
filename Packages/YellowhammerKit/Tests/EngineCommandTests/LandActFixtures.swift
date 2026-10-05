import Domain
@testable import Engine
import Foundation
@testable import Journal
import Repositories
import Testing

// roadmap P10.1: shared fixtures and stub seams for LandActTests.swift, LandActOnceLandedTests.swift.

let landEpoch = Date(timeIntervalSince1970: 1_800_000_000)
let landNightStart = NightStart(rawValue: "2026-09-16")!
let landBranch = FeatureBranch(rawValue: "yh-proj-feat")

/// Records every seam call, in order, shared by reference between stubs.
final class LandCallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func add(_ entry: String) {
        lock.lock()
        entries.append(entry)
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}

struct StubMergeTest: LaneMergeTesting {
    let log: LandCallLog
    var conflict = false

    func test(_ context: LandActLaneContext) async throws -> MergeTestOutcome {
        log.add("mergeTest:\(context.lane.repository)")
        return MergeTestOutcome(conflict: conflict)
    }
}

struct StubPush: LanePushing {
    let log: LandCallLog
    /// Repositories whose push reports not-pushed.
    var notPushed: Set<String> = []
    /// Repositories whose push seam throws.
    var throwing: Set<String> = []
    /// Repositories whose Feature Branch is at its base: the push reports no completed work.
    var noCompletedWork: Set<String> = []

    struct PushError: Error, Equatable {}

    func push(_ context: LandActLaneContext) async throws -> LanePushOutcome {
        log.add("push:\(context.lane.repository)")
        if throwing.contains(context.lane.repository) {
            throw PushError()
        }
        if noCompletedWork.contains(context.lane.repository) {
            return LanePushOutcome(kind: .noCompletedWork)
        }
        if notPushed.contains(context.lane.repository) {
            return LanePushOutcome(pushed: false, reason: "rejected")
        }
        return LanePushOutcome(pushed: true, commit: "deadbeef-\(context.lane.repository)")
    }
}

struct StubPullRequest: PullRequestOpening {
    let log: LandCallLog

    func open(
        _ context: LandActLaneContext, push: LanePushOutcome, mergeOutcome: MergeTestOutcome?
    ) async throws -> PullRequestOutcome {
        log.add("openPullRequest:\(context.lane.repository)")
        return PullRequestOutcome(opened: true)
    }
}

struct StubVerification: FeatureVerifying {
    let log: LandCallLog
    var verdict: VerificationVerdict

    func verify(_ context: LandActFeatureContext) async throws -> VerificationVerdict {
        log.add("verification")
        return verdict
    }
}

struct StubReturnFeature: FeatureReturning {
    let log: LandCallLog

    func returnFeature(_ context: LandActFeatureContext, verdict: VerificationVerdict) async throws {
        log.add("returnFeature")
    }
}

struct StubArchiveCycle: CycleArchiving {
    let log: LandCallLog

    func archive(_ context: LandActFeatureContext) async throws {
        log.add("archiveCycle")
    }
}

/// A fixture Feature → Cycle → two Cards in two repositories (one lane each), with a Feature Branch
/// recorded and, when `worktrees` is true, a held Worktree per lane.
struct LandFixture {
    let journal: JournalStore
    let featureID: Int64
    let cycleID: Int64
    let repositories = ["backend", "mobile"]

    static func make(_ journal: JournalStore, runID: RunID, worktrees: Bool = true) throws -> LandFixture {
        let featureID = try insertReconcilerFeature(journal, issueID: "FEAT-1")
        try journal.recordWorktreeName(featureID: featureID, worktreeName: WorktreeName(rawValue: landBranch.rawValue))
        let cycleID = try insertReconcilerCycle(journal, featureID: featureID)
        try insertReconcilerCard(journal, cycleID: cycleID, issueID: "BACK-1", repository: "backend", state: .done)
        try insertReconcilerCard(journal, cycleID: cycleID, issueID: "MOB-1", repository: "mobile", state: .done)
        let fixture = LandFixture(journal: journal, featureID: featureID, cycleID: cycleID)
        // Production records the touched repositories at authoring; the Cards above name them all.
        try recordTouchedRepositories(journal, featureID: featureID, repositories: fixture.repositories)
        if worktrees {
            for repository in fixture.repositories {
                try journal.recordWorktree(
                    featureID: featureID, repository: repository, worktreeID: "wt-\(repository)",
                    path: "/tmp/\(repository)", runID: runID
                )
            }
        }
        return fixture
    }
}

/// Claims the land Act's lease for direct Journal setup, ahead of the real invocation claiming it again
/// under the same runID (claiming is reentrant for the same run).
func claimLandLease(_ journal: JournalStore, runID: RunID, mode: NightMode = .real) throws {
    guard case .claimed = try journal.claimActLease(act: .land, runID: runID, mode: mode, now: landEpoch) else {
        Issue.record("Could not claim the land Act's lease")
        return
    }
}

func heldWorktreeIDs(_ journal: JournalStore, featureID: Int64) throws -> [String: Bool] {
    try Dictionary(
        uniqueKeysWithValues: journal.worktrees(featureID: featureID).map { ($0.repository, $0.isHeld) }
    )
}

/// Records `feature_repository` rows, as authoring does for the repositories a Feature's Cycle touches.
func recordTouchedRepositories(_ journal: JournalStore, featureID: Int64, repositories: [String]) throws {
    try journal.write { database in
        try JournalStore.insertFeatureRepositories(database, featureID: featureID, repositories: repositories)
    }
}
