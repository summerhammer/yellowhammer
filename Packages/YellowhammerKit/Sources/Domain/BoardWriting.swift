import Foundation

/// The writing half of the Board Port (ADR-001): how the Outbox lands one write on the board.
///
/// An implementation is bound to exactly one Project's Linear project when it is constructed, and every
/// write it performs addresses that Linear project. It translates and never decides: the Outbox above it
/// owns idempotency (deterministic client ids, replay), the pre-flight read-modify-write of a
/// description, Lease revalidation and the recording of every outcome. Nothing here retries.
public protocol BoardWriting: Sendable {
    /// The pre-flight read that precedes a description rewrite: the issue's description as it is at this
    /// instant, never from a cache. Throws `scopeNotFound` when the issue is not in this Project's Linear
    /// project or does not exist.
    func issueDescription(_ issue: BoardObjectID) async throws(BoardError) -> BoardDescriptionSnapshot

    /// Creates an issue in this Project's Linear project under a client-supplied id. Sending the same
    /// `clientID` twice creates nothing the second time: the board's "conflict on insert" is reported as
    /// ``BoardCreateReceipt/alreadyApplied(_:)``, never as an error.
    func createIssue(_ draft: BoardIssueDraft, clientID: UUID) async throws(BoardError) -> BoardCreateReceipt

    /// Posts a comment on an issue under a client-supplied id, with the same replay contract as
    /// ``createIssue(_:clientID:)``.
    func createComment(
        on issue: BoardObjectID, body: String, clientID: UUID
    ) async throws(BoardError) -> BoardCreateReceipt

    /// Attaches a link to an issue under a client-supplied id, with the same replay contract as
    /// ``createIssue(_:clientID:)``.
    func attachLink(
        to issue: BoardObjectID, url: String, title: String, clientID: UUID
    ) async throws(BoardError) -> BoardCreateReceipt

    /// Applies one change to an issue and returns the description and `updatedAt` the board holds after
    /// it, so a description write can be audited against what was sent.
    func updateIssue(
        _ issue: BoardObjectID, _ change: BoardIssueChange
    ) async throws(BoardError) -> BoardDescriptionSnapshot

    /// Archives an issue. Throws `scopeNotFound` when the issue is not in this Project's Linear project.
    func archiveIssue(_ issue: BoardObjectID) async throws(BoardError)
}

/// An issue's description as the board held it at one instant.
public struct BoardDescriptionSnapshot: Equatable, Sendable {
    public var id: BoardObjectID
    public var description: String?
    public var updatedAt: Date

    public init(id: BoardObjectID, description: String?, updatedAt: Date) {
        self.id = id
        self.description = description
        self.updatedAt = updatedAt
    }
}

/// What a create came back as: the board applied it now, or had already applied a write under the
/// same client id. Either way the object exists exactly once.
public enum BoardCreateReceipt: Equatable, Sendable {
    case created(BoardObjectID)
    case alreadyApplied(BoardObjectID)

    public var id: BoardObjectID {
        switch self {
        case .created(let id), .alreadyApplied(let id):
            id
        }
    }
}

/// A new issue, as the Outbox describes it: a Card, a Feature Issue or a Night Card. The Linear project
/// is the adapter's, bound at construction, so it is not here; the team is, because the board requires
/// one and a Linear project may span several.
public struct BoardIssueDraft: Codable, Equatable, Sendable {
    public var team: BoardObjectID
    public var title: String
    public var description: String?
    /// The Feature Issue a Card is created as a native sub-issue of.
    public var parent: BoardObjectID?
    public var labels: [BoardObjectID]
    public var workflowState: BoardObjectID?
    public var assignee: BoardObjectID?

    public init(
        team: BoardObjectID,
        title: String,
        description: String? = nil,
        parent: BoardObjectID? = nil,
        labels: [BoardObjectID] = [],
        workflowState: BoardObjectID? = nil,
        assignee: BoardObjectID? = nil
    ) {
        self.team = team
        self.title = title
        self.description = description
        self.parent = parent
        self.labels = labels
        self.workflowState = workflowState
        self.assignee = assignee
    }
}

/// One change to an issue. Every field is optional and only the fields given are sent, so a workflow
/// state change carries no description and cannot clobber one. Labels are added and removed by id
/// rather than replaced, so a label the Operator put on the issue survives.
public struct BoardIssueChange: Codable, Equatable, Sendable {
    public var title: String?
    public var description: String?
    public var workflowState: BoardObjectID?
    public var addLabels: [BoardObjectID]
    public var removeLabels: [BoardObjectID]
    public var assignee: BoardReferenceChange?
    /// Set to nest the issue under a Feature Issue, clear to detach it.
    public var parent: BoardReferenceChange?

    public init(
        title: String? = nil,
        description: String? = nil,
        workflowState: BoardObjectID? = nil,
        addLabels: [BoardObjectID] = [],
        removeLabels: [BoardObjectID] = [],
        assignee: BoardReferenceChange? = nil,
        parent: BoardReferenceChange? = nil
    ) {
        self.title = title
        self.description = description
        self.workflowState = workflowState
        self.addLabels = addLabels
        self.removeLabels = removeLabels
        self.assignee = assignee
        self.parent = parent
    }

    /// True when nothing would be sent.
    public var isEmpty: Bool {
        title == nil && description == nil && workflowState == nil && addLabels.isEmpty && removeLabels.isEmpty
            && assignee == nil && parent == nil
    }
}

/// A reference field's new value: point it at an object, or clear it.
public enum BoardReferenceChange: Codable, Equatable, Sendable {
    case set(BoardObjectID)
    case clear
}
