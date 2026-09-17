import Domain
import Journal

/// What a build Act hands each Repo Lane's Card to, one at a time (graph-execution/run-a-card is
/// P8.4, a later phase). A throw is an engine fault that stops the lane; Card-level outcomes (Blocked,
/// Waiting on You, Rounds, Attempts) are the runner's to record in the Journal and never thrown.
public protocol CardRunner: Sendable {
    /// `readiness` is what the Readiness Check (P8.2) found Ready for this Card: its brief and its
    /// Definition of Done. A `BuildAct` given no `readiness: ReadinessCheck?` (the unchecked path used
    /// only by tests that predate P8.2) passes an empty `CardReadiness` here instead of running the check.
    func run(card: CardRecord, in lane: RepoLane, context: BuildActContext, readiness: CardReadiness) async throws
}

/// Everything a ``CardRunner`` needs for one Card: the Act it is running under, the in-flight Feature
/// and Cycle, the Worktree reconciliation this Act performed, and the Delta Read's report — nil when
/// this invocation was given no Board.
public struct BuildActContext: Sendable {
    public let act: ActContext
    public let feature: FeatureRecord
    public let cycleID: Int64
    public let reconciliation: WorktreeReconciliation
    public let deltaRead: DeltaReadReport?

    public init(
        act: ActContext,
        feature: FeatureRecord,
        cycleID: Int64,
        reconciliation: WorktreeReconciliation,
        deltaRead: DeltaReadReport?
    ) {
        self.act = act
        self.feature = feature
        self.cycleID = cycleID
        self.reconciliation = reconciliation
        self.deltaRead = deltaRead
    }
}
