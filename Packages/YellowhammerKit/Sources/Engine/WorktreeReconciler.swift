import Domain
import Foundation
import Journal
import Repositories

/// The outcome of reconciling one held Worktree (loop-state/reconcile-worktrees-at-act-start).
public enum WorktreeReconciliationOutcome: Equatable, Sendable {
    /// The path exists, is quiescent and holds no uncommitted work.
    case clean(WorktreeRecord)
    /// Ghost Worktree: the recorded path no longer exists. Orca ADE's stale record was purged,
    /// the Journal marks it lost, and this repository's in-progress Cards return to Todo.
    case lost(WorktreeRecord)
    /// Uncommitted work was committed as a WIP commit on the Feature Branch, the Worktree reset to
    /// the last known-good commit (`resetTo`, nil when no known-good commit is recorded), and the
    /// WIP ref recorded for the retry.
    case wipCommitted(WorktreeRecord, wipCommit: String, wipRef: String, resetTo: String?)
    /// Processes still held the path after the fencing timeout; nothing was inspected, committed or reset.
    case notQuiescent(WorktreeRecord, remaining: Int)
    /// A git step refused or failed; nothing was destroyed. `reason` says what.
    case failed(WorktreeRecord, reason: String)
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

    /// True when every outcome is dispatchable — `.clean`, `.lost` or `.wipCommitted` — the lanes a
    /// dispatch may proceed on. False when any repository is `.notQuiescent` or `.failed`: half-finished
    /// edits that must not be dispatched over.
    public var isDispatchable: Bool {
        outcomes.values.allSatisfy { outcome in
            switch outcome {
            case .notQuiescent, .failed:
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
/// purges the ghost and returns that repository's in-progress Cards to Todo; otherwise fences the
/// path quiescent, then commits any uncommitted edits as a WIP commit on the Feature Branch and resets
/// to the last known-good commit. ``WorktreeReconciliation/isDispatchable`` and each repository's
/// outcome are what the build Act must consult before dispatching: a `.notQuiescent` or `.failed` lane
/// means half-finished edits are still sitting there, and dispatch must not proceed on top of them.
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

    public init(
        workspace: any Workspace,
        journal: JournalStore,
        runID: RunID,
        act: Act,
        nightID: Int64?,
        git: GitRunner = GitRunner(),
        committer: WorktreeCommitter = WorktreeCommitter(),
        fencer: ProcessFencer = ProcessFencer()
    ) {
        self.workspace = workspace
        self.journal = journal
        self.runID = runID
        self.act = act
        self.nightID = nightID
        self.git = git
        self.committer = committer
        self.fencer = fencer
    }

    /// Reconciles every held Worktree recorded for `featureID` — this Project's in-flight Feature —
    /// in repository order. Only the Journal's records are swept: the Workspace Port's list is
    /// never consulted, so a worktree this Act cannot account for (a sibling Project's) is never
    /// verified, fenced, committed or reset.
    public func reconcile(featureID: Int64, branch: FeatureBranch) async throws -> WorktreeReconciliation {
        let held = try journal.worktrees(featureID: featureID)
            .filter(\.isHeld)
            .sorted { $0.repository < $1.repository }

        var outcomes: [String: WorktreeReconciliationOutcome] = [:]
        for record in held {
            outcomes[record.repository] = try await reconcileOne(record, branch: branch)
        }
        return WorktreeReconciliation(outcomes)
    }

    private func reconcileOne(
        _ record: WorktreeRecord, branch: FeatureBranch
    ) async throws -> WorktreeReconciliationOutcome {
        let path = Self.expandedPath(record.path)
        guard FileManager.default.fileExists(atPath: path) else {
            return try await purgeGhost(record)
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
            return try await purgeGhost(record)
        }

        return try await reconcileCommitState(record, branch: branch)
    }

    static func expandedPath(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}
