import Domain
import Foundation
import Journal
import Repositories

/// Everything an Act's work is handed: the one Project's Journal and this run's identity. There is
/// nothing else to hand it — a resumed Act rebuilds Attempt and Round counts, routes tried and
/// Worktree paths from the Journal, and an invocation holds nothing in memory between Acts.
public struct ActContext: Sendable {
    public let act: Act
    public let mode: NightMode
    public let trigger: ActTrigger
    public let runID: RunID
    public let journal: JournalStore
    /// The Night this Act belongs to. Once a Board is given, this carries the Night Card's issue id,
    /// re-read after `open` recorded it.
    public let night: NightRecord
    /// The single write path to the board, when this invocation was given one.
    public let outbox: Outbox?
    /// This Act's Night Card, when this invocation was given a Board.
    public let nightCard: NightCardMaintenance?
    /// The Board Port, when this invocation was given one. The Engine never imports an adapter (MB1);
    /// `EngineCommand` is the one place this is wired.
    public let board: ActBoard?
    /// Resolved mainlines for this Project's repositories.
    public let mainlines: ResolvedMainlines
    /// The Workspace Port, when this invocation was given one. The Engine never imports an adapter
    /// (MB1); `EngineCommand` is the one place this is wired.
    public let workspace: (any Workspace)?
    /// The Project's configured repositories, when provided — the Readiness Check's provenance and
    /// citation resolution need these to test a Transcription Block or resolve a Spec Citation.
    public let repositories: ProjectRepositories?
    /// The Operator's board identity, machine-configured (roadmap P11.1; carried on the context itself,
    /// not threaded through each consumer's initializer, since every consumer already has this).
    public let operatorIdentity: OperatorIdentity
    /// The `feature_base` rows the author Act's selection records with the Feature it authors (roadmap P23.2):
    /// set only on the context ``ActContext/authoring(against:)`` derives; empty everywhere else.
    public var unansweredNightsMax: Int = 3
    public var landHoldSchedule: LandHoldSchedule?
    public let featureBases: [FeatureBaseRecord]

    public init(
        act: Act,
        mode: NightMode,
        trigger: ActTrigger,
        runID: RunID,
        journal: JournalStore,
        night: NightRecord,
        outbox: Outbox? = nil,
        nightCard: NightCardMaintenance? = nil,
        board: ActBoard? = nil,
        mainlines: ResolvedMainlines = ResolvedMainlines(),
        workspace: (any Workspace)? = nil,
        repositories: ProjectRepositories? = nil,
        operatorIdentity: OperatorIdentity = .none,
        featureBases: [FeatureBaseRecord] = []
    ) {
        self.act = act
        self.mode = mode
        self.trigger = trigger
        self.runID = runID
        self.journal = journal
        self.night = night
        self.outbox = outbox
        self.nightCard = nightCard
        self.board = board
        self.mainlines = mainlines
        self.workspace = workspace
        self.repositories = repositories
        self.operatorIdentity = operatorIdentity
        self.featureBases = featureBases
    }
}
