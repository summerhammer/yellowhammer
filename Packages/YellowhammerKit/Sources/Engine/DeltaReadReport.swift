import Domain
import Foundation
import Journal

/// What one Delta Read concluded, or that it could not read.
public enum DeltaReadOutcome: Equatable, Sendable {
    case read(DeltaReadReport)
    /// The board refused for its rate budget before the read completed. Nothing read this Act was acted
    /// on, no sync point moved, and the degradation was recorded as workspace-wide.
    case degraded(reason: String)
}

/// Everything an Act learns from one Delta Read, before any dispatch decision. The Journal stays
/// authoritative for loop state: what is reported here was reconciled against it, never adopted from
/// the board — except Cancelled, the one state Yellowhammer reads and never writes.
public struct DeltaReadReport: Equatable, Sendable {
    /// The sync point the read started from; nil for a first read.
    public var since: Date?
    /// The sync point recorded after the read: the latest board timestamp seen, or `since` unchanged
    /// when nothing had changed.
    public var syncPoint: Date?
    /// How many requests the read cost. One, unless a page overflowed.
    public var requests: Int
    /// Every known Card that appeared among the updated objects, with what was observed on it.
    public var cardChanges: [CardChange]
    /// Comments not written by Yellowhammer's own identity, oldest first.
    public var humanComments: [HumanComment]
    /// How many of Yellowhammer's own comments were filtered out.
    public var ownComments: Int
    /// Cards the board read as Cancelled that the Journal did not have as cancelled; now recorded.
    public var cancelled: [CardRecord]
    /// Journal-cancelled Cards the board read as reopened; restored to the state they held.
    public var reopened: [CardRecord]
    /// Cards whose board state the Journal did not write. Reported, never adopted.
    public var restated: [RestatedCard]
    /// Cards the Operator deleted or archived while the Journal still had them in play.
    public var removed: [RemovedCard]
    /// Cards whose board copy breaks the authoring invariant. Reported instead of dispatched.
    public var invariantBreaks: [InvariantBreak]
    /// Updated objects the Journal has no Card for: Feature Issues, Night Cards, the Operator's own issues.
    public var unknownObjects: [BoardObject]
    /// A Card read in Waiting on You with no Journal record behind it: an unknown object labelled Card,
    /// or a known Card whose Journal state is Waiting on You with no waiting reason recorded (glossary
    /// → Waiting on You; bounds/escalate-a-question-to-the-operator).
    public var anomalies: [WaitingOnYouAnomaly]

    public init(
        since: Date?,
        syncPoint: Date?,
        requests: Int,
        cardChanges: [CardChange] = [],
        humanComments: [HumanComment] = [],
        ownComments: Int = 0,
        cancelled: [CardRecord] = [],
        reopened: [CardRecord] = [],
        restated: [RestatedCard] = [],
        removed: [RemovedCard] = [],
        invariantBreaks: [InvariantBreak] = [],
        unknownObjects: [BoardObject] = [],
        anomalies: [WaitingOnYouAnomaly] = []
    ) {
        self.since = since
        self.syncPoint = syncPoint
        self.requests = requests
        self.cardChanges = cardChanges
        self.humanComments = humanComments
        self.ownComments = ownComments
        self.cancelled = cancelled
        self.reopened = reopened
        self.restated = restated
        self.removed = removed
        self.invariantBreaks = invariantBreaks
        self.unknownObjects = unknownObjects
        self.anomalies = anomalies
    }

    /// The Card changes that carry a signal Yellowhammer did not write itself: an Operator's edit to
    /// the block, the prose, the state, or the delimiters. Surfaced before any dispatch decision.
    public var operatorEdits: [CardChange] {
        cardChanges.filter(\.hasOperatorSignal)
    }

    /// The issue ids `anomalies` named: never dispatched — dispatch (a later phase) must exclude these.
    public var anomalousIssueIDs: Set<String> {
        Set(anomalies.map(\.issueID))
    }
}

/// A Waiting on You Card with no Journal record behind it, as the Delta Read found it.
public struct WaitingOnYouAnomaly: Equatable, Sendable {
    /// The board object's id.
    public var issueID: String
    /// The board's human identifier, such as `ENG-123`.
    public var key: String
    /// The Journal's Card id, when the anomaly is a known Card; nil for an unknown object.
    public var cardID: Int64?
    public var reason: String

    public init(issueID: String, key: String, cardID: Int64?, reason: String) {
        self.issueID = issueID
        self.key = key
        self.cardID = cardID
        self.reason = reason
    }
}

/// A known Card as it appeared among the updated objects, compared with what the Journal knows.
public struct CardChange: Equatable, Sendable {
    public var card: CardRecord
    /// The Card's board copy: title, description, labels, assignment, parent and state as read.
    public var object: BoardObject
    /// The board's workflow state is not the Journal's, and no write to this issue is pending.
    public var stateDiffers: Bool
    /// The Managed Block read back does not hash to the block last posted; nil when the Journal has
    /// never posted one or the delimiters are broken.
    public var managedBlockEdited: Bool?
    /// The prose outside the delimiters does not hash to what the last write preserved; nil when no
    /// write was recorded or the delimiters are broken.
    public var proseEdited: Bool?
    /// The delimiters are missing or malformed; nil when the description could be fenced.
    public var delimitersBroken: ManagedBlockFence.Failure?
    /// The repository the Managed Block names, when it names one.
    public var repositoryOnBoard: String?

    public init(
        card: CardRecord,
        object: BoardObject,
        stateDiffers: Bool,
        managedBlockEdited: Bool?,
        proseEdited: Bool?,
        delimitersBroken: ManagedBlockFence.Failure?,
        repositoryOnBoard: String?
    ) {
        self.card = card
        self.object = object
        self.stateDiffers = stateDiffers
        self.managedBlockEdited = managedBlockEdited
        self.proseEdited = proseEdited
        self.delimitersBroken = delimitersBroken
        self.repositoryOnBoard = repositoryOnBoard
    }

    public var hasOperatorSignal: Bool {
        stateDiffers || managedBlockEdited == true || proseEdited == true || delimitersBroken != nil
    }
}

/// A comment a human wrote, with the Card it is on when the Journal knows one.
public struct HumanComment: Equatable, Sendable {
    public var comment: BoardComment
    public var card: CardRecord?
    /// A threaded reply. Whether it answers Yellowhammer's question is decided where the question's
    /// comment id is known (spec G-8), not here.
    public var isThreadedReply: Bool { comment.parent != nil }

    public init(comment: BoardComment, card: CardRecord?) {
        self.comment = comment
        self.card = card
    }
}

public struct RestatedCard: Equatable, Sendable {
    public var card: CardRecord
    public var boardState: BoardWorkflowState

    public init(card: CardRecord, boardState: BoardWorkflowState) {
        self.card = card
        self.boardState = boardState
    }
}

public struct RemovedCard: Equatable, Sendable {
    public enum How: String, Sendable {
        case trashed, archived
    }

    public var card: CardRecord
    public var how: How

    public init(card: CardRecord, how: How) {
        self.card = card
        self.how = how
    }
}

public struct InvariantBreak: Equatable, Sendable {
    public var card: CardRecord
    public var reason: String

    public init(card: CardRecord, reason: String) {
        self.card = card
        self.reason = reason
    }
}

public enum DeltaReadError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The board could not be read for a reason other than its rate budget. Nothing was acted on.
    case boardUnavailable(BoardError)
    /// Pages kept coming past any plausible number; the read stopped rather than loop.
    case tooManyPages(requests: Int)

    public var description: String {
        switch self {
        case .boardUnavailable(let error):
            "the Delta Read could not complete, so this Act acts on nothing it read: \(error)"
        case .tooManyPages(let requests):
            "the Delta Read stopped after \(requests) requests without reaching the last page"
        }
    }
}
