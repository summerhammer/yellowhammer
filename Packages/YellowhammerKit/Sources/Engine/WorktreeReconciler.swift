import Domain
import Foundation
import Journal
import Repositories

/// The outcome of reconciling one held Worktree (loop-state/reconcile-worktrees-at-act-start).
public enum WorktreeReconciliationOutcome: Equatable, Sendable {
    /// The path exists, is quiescent and holds no uncommitted work.
    case clean(WorktreeRecord)
    /// Ghost Worktree: the recorded path no longer exists. The Feature Branch tip was pinned at
    /// `refs/yellowhammer/recovery/<branch>` (when the branch still existed), Orca ADE's stale record was
    /// purged, the Journal marks it lost, and this repository's in-progress Cards return to Todo.
    case lost(WorktreeRecord)
    /// Uncommitted work was committed as a WIP commit on the Feature Branch, the Worktree reset to
    /// the last known-good commit (`resetTo`, nil when no known-good commit is recorded), and the
    /// WIP ref recorded for the retry.
    case wipCommitted(WorktreeRecord, wipCommit: String, wipRef: String, resetTo: String?)
    /// Processes still held the path after the fencing timeout; nothing was inspected, committed or reset.
    case notQuiescent(WorktreeRecord, remaining: Int)
    /// A git step refused or failed; nothing was destroyed. `reason` says what.
    case failed(WorktreeRecord, reason: String)
    /// Ghost Worktree whose Feature Branch could not be pinned (OQ123): Orca ADE was not asked to remove
    /// it, the Worktree stays held at a path that no longer exists, and the failure is recorded.
    case ghostKept(WorktreeRecord, reason: String)
}

/// Every held Worktree's reconciliation outcome for one Feature, keyed by repository.
public struct WorktreeReconciliation: Equatable, Sendable {
    public let outcomes: [String: WorktreeReconciliationOutcome]

    public init(_ outcomes: [String: WorktreeReconciliationOutcome] = [:]) {
        self.outcomes = outcomes
    }

    /// The outcome recorded for `repository`, nil when this Feature holds no Worktree there.
    public subscript(repository: String) -> WorktreeReconciliationOutcome? {
        outcomes[repository]
    }

    public var repositories: [String] { outcomes.keys.sorted() }

    /// Why `repository`'s lane must not be dispatched over, nil when it may be. Only a `.ghostKept`
    /// outcome gives a reason: its held Worktree points at a directory that no longer exists (OQ123), so
    /// the allocator would reuse it, dispatch a Card into nothing and spend an Attempt. `.failed` and
    /// `.notQuiescent` deliberately give none and dispatch as they did before the recovery pin — gating
    /// them in general is a separate, pre-existing gap that conflicts with the rehearsal contract (a
    /// rehearsal Night leaves a dirty Worktree in place, which reconciles `.failed`, and still runs).
    public func undispatchableReason(for repository: String) -> String? {
        switch outcomes[repository] {
        case .ghostKept(_, let reason):
            "Worktree reconciliation did not settle \(repository): \(reason)"
        case .clean, .lost, .wipCommitted, .notQuiescent, .failed, nil:
            nil
        }
    }

    /// True when every outcome is dispatchable — `.clean`, `.lost` or `.wipCommitted` — the lanes a
    /// dispatch may proceed on. False when any repository is `.notQuiescent`, `.failed` or `.ghostKept`:
    /// half-finished edits (or a held Worktree with no directory) that must not be dispatched over.
    public var isDispatchable: Bool {
        outcomes.values.allSatisfy { outcome in
            switch outcome {
            case .notQuiescent, .failed, .ghostKept:
                false
            case .clean, .lost, .wipCommitted:
                true
            }
        }
    }
}

/// Reconciles every Worktree a Feature holds at build Act start (loop-state/reconcile-worktrees-at-act-start).
///
/// The build Act (roadmap P8.1) sequences this after lease reclaim and before board repost: a killed
/// Attempt can leave a Worktree mid-edit, or a Worktree Orca ADE has since lost track of, and neither
/// state may be dispatched over silently. Per held Worktree, in repository order, this: stats the
/// recorded path (never asking the Workspace Port to list — only the Journal's own records for this
/// Feature are ever swept, so a sibling Project's Worktree is never touched); if the path is gone,
/// pins the Feature Branch tip at `refs/yellowhammer/recovery/<branch>` in the main repository (Orca ADE
/// deletes a removed Worktree's branch, and before the land Act it is unpushed — OQ123), purges the
/// ghost and returns that repository's in-progress Cards to Todo; otherwise fences the
/// path quiescent, then commits any uncommitted edits as a WIP commit on the Feature Branch and resets
/// to the last known-good commit. A ghost whose Feature Branch cannot be pinned is kept, not purged
/// (`.ghostKept`). The build Act consults ``WorktreeReconciliation/undispatchableReason(for:)``, which
/// today stops only a `.ghostKept` lane; a `.notQuiescent` or `.failed` lane still dispatches, as before
/// OQ123 (a rehearsal Night's dirty Worktree reconciles to `.failed` and its lane runs).
public struct WorktreeReconciler: Sendable {
    public let workspace: any Workspace
    public let journal: JournalStore
    public let runID: RunID
    /// Stamped on every event this reconciliation appends: the build Act.
    public let act: Act
    /// Stamped on every event this reconciliation appends.
    public let nightID: Int64?
    public let git: GitRunner
    public let committer: WorktreeCommitter
    public let fencer: ProcessFencer
    /// The Project's configured repositories: how a ghost-Worktree purge finds the MAIN repository to pin
    /// the Feature Branch in (OQ123). Nil when none is bound; a ghost then cannot be pinned, so it is held.
    public let repositories: ProjectRepositories?
    /// Pins a ghost Worktree's Feature Branch tip before the purge (OQ123).
    public let recoveryPin: FeatureBranchRecoveryPin
    /// How long a purge waits for Orca ADE to delete the removed Worktree's branch before moving on.
    public let branchDeletionTimeout: Duration
    /// How often a purge re-checks whether that branch is gone.
    public let branchDeletionPollInterval: Duration

    public init(
        workspace: any Workspace,
        journal: JournalStore,
        runID: RunID,
        act: Act,
        nightID: Int64?,
        git: GitRunner = GitRunner(),
        committer: WorktreeCommitter = WorktreeCommitter(),
        fencer: ProcessFencer = ProcessFencer(),
        repositories: ProjectRepositories? = nil,
        recoveryPin: FeatureBranchRecoveryPin? = nil,
        branchDeletionTimeout: Duration = .seconds(30),
        branchDeletionPollInterval: Duration = .milliseconds(500)
    ) {
        self.workspace = workspace
        self.journal = journal
        self.runID = runID
        self.act = act
        self.nightID = nightID
        self.git = git
        self.committer = committer
        self.fencer = fencer
        self.repositories = repositories
        self.recoveryPin = recoveryPin ?? FeatureBranchRecoveryPin(git: git)
        self.branchDeletionTimeout = branchDeletionTimeout
        self.branchDeletionPollInterval = branchDeletionPollInterval
    }

    /// Reconciles every held Worktree recorded for `feature` — this Project's in-flight Feature —
    /// in repository order, each against the Feature Branch resolved for its repository
    /// (``JournalStore/resolvedFeatureBranch(feature:repository:)``); a held Worktree with none throws
    /// ``BuildActError/featureBranchUnrecorded(featureID:)``. Only the Journal's records are swept: the
    /// Workspace Port's list is never consulted, so a worktree this Act cannot account for (a sibling
    /// Project's) is never verified, fenced, committed or reset.
    public func reconcile(feature: FeatureRecord) async throws -> WorktreeReconciliation {
        let held = try journal.worktrees(featureID: feature.id)
            .filter(\.isHeld)
            .sorted { $0.repository < $1.repository }

        var outcomes: [String: WorktreeReconciliationOutcome] = [:]
        for record in held {
            guard let branch = try journal.resolvedFeatureBranch(feature: feature, repository: record.repository) else {
                throw BuildActError.featureBranchUnrecorded(featureID: feature.id)
            }
            outcomes[record.repository] = try await reconcileOne(record, branch: branch)
        }
        return WorktreeReconciliation(outcomes)
    }

    private func reconcileOne(
        _ record: WorktreeRecord, branch: FeatureBranch
    ) async throws -> WorktreeReconciliationOutcome {
        let path = Self.expandedPath(record.path)
        guard FileManager.default.fileExists(atPath: path) else {
            return try await purgeGhost(record, branch: branch)
        }

        switch await fencer.fence(worktreePath: path) {
        case .quiescent(let killed):
            if !killed.isEmpty {
                try journal.append(
                    .worktreeFenced(
                        featureID: record.featureID, repository: record.repository,
                        path: record.path, killed: killed.count
                    ),
                    act: act, runID: runID, nightID: nightID
                )
            }
        case .notQuiescent(_, let remaining):
            try journal.append(
                .worktreeNotQuiescent(
                    featureID: record.featureID, repository: record.repository,
                    path: record.path, remaining: remaining.count
                ),
                act: act, runID: runID, nightID: nightID
            )
            return .notQuiescent(record, remaining: remaining.count)
        case .pathMissing:
            // Unreachable: the fileExists check above already ruled this out. Treated as a ghost
            // defensively rather than assumed impossible.
            return try await purgeGhost(record, branch: branch)
        }

        return try await reconcileCommitState(record, branch: branch)
    }

    static func expandedPath(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}
