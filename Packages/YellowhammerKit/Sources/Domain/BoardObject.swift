import Foundation

/// One issue on the board: a Card, a Feature Issue or a Night Card — a board object.
///
/// Which of those it is, and what its state means, is decided above the Board Port; this is only what
/// the board reported.
public struct BoardObject: Equatable, Sendable, Codable {
    public var id: BoardObjectID
    /// The human identifier, such as `ENG-123`.
    public var key: String
    public var title: String
    public var description: String?
    public var workflowState: BoardWorkflowState
    public var labels: [String]
    /// The Feature Issue a Card is a native sub-issue of; nil for an object with no parent.
    public var parent: BoardObjectID?
    /// Who the object is assigned to; nil when unassigned.
    public var assignee: BoardObjectID?
    public var url: String
    public var createdAt: Date
    public var updatedAt: Date
    /// When the object was archived on the board; nil while it is live. An object the Operator
    /// deleted is archived and `isTrashed`.
    public var archivedAt: Date?
    public var isTrashed: Bool

    public init(
        id: BoardObjectID,
        key: String,
        title: String,
        description: String?,
        workflowState: BoardWorkflowState,
        labels: [String],
        parent: BoardObjectID?,
        assignee: BoardObjectID? = nil,
        url: String,
        createdAt: Date,
        updatedAt: Date,
        archivedAt: Date? = nil,
        isTrashed: Bool = false
    ) {
        self.id = id
        self.key = key
        self.title = title
        self.description = description
        self.workflowState = workflowState
        self.labels = labels
        self.parent = parent
        self.assignee = assignee
        self.url = url
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.archivedAt = archivedAt
        self.isTrashed = isTrashed
    }
}

/// A workflow state as the board names it. The name is what carries `Waiting on You`.
public struct BoardWorkflowState: Hashable, Sendable, Codable {
    public var id: BoardObjectID
    public var name: String
    /// Yellowhammer's vocabulary for what the vendor's state `type` means; nil when the vendor
    /// reported a type this build does not know. An adapter translates the vendor's string into this
    /// enum so nothing above the Board Port ever reads a vendor type directly.
    public var category: BoardWorkflowStateCategory?
    /// The state's place among its team's states (Linear's `position`, a float). Native selection by
    /// category takes the lowest position first; nil, for a board that reports none, sorts last.
    public var position: Double?

    public init(
        id: BoardObjectID, name: String, category: BoardWorkflowStateCategory? = nil, position: Double? = nil
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.position = position
    }

    /// True when the board itself says this state is shelved: its category is the cancelled one. A name
    /// decides nothing (a team's own state called `Shelved` is not Yellowhammer's, roadmap P22.9). The one
    /// shared predicate every Shelved comparison routes through.
    public var isShelved: Bool {
        category == .shelved
    }
}

/// Yellowhammer's vocabulary for a workflow state's category, translated from the board's own by an
/// adapter (an adapter translates, never decides). Linear spells its cancelled type `canceled`; this
/// enum keeps Yellowhammer's own spelling.
public enum BoardWorkflowStateCategory: String, Sendable, CaseIterable, Codable {
    case triage
    case backlog
    case unstarted
    case started
    case completed
    case shelved
}
