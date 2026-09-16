import Foundation

/// One issue on the board: a Card, a Feature Issue or a Night Card — a board object.
///
/// Which of those it is, and what its state means, is decided above the Board Port; this is only what
/// the board reported.
public struct BoardObject: Equatable, Sendable {
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
public struct BoardWorkflowState: Hashable, Sendable {
    public var id: BoardObjectID
    public var name: String

    public init(id: BoardObjectID, name: String) {
        self.id = id
        self.name = name
    }
}
