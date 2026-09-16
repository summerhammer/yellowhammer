import Foundation

/// What one Delta Read brought back: the board objects updated and the comments created since the
/// sync point, both scoped to this Project's Linear project, from one request.
///
/// Comments are read alongside issues because a comment does not bump its issue's `updatedAt`, and a
/// human reply on a Waiting on You Card is the re-entry signal. Nothing here is filtered or judged:
/// which comments are Yellowhammer's own, which objects are Cards, and what a change means are
/// decided above the Board Port.
public struct BoardDelta: Equatable, Sendable {
    /// Who the board says Yellowhammer is, read in the same request, so a comment's author can be
    /// matched against it without a second call.
    public var identity: BoardIdentity
    /// Board objects updated after the sync point, oldest update first.
    public var updatedObjects: [BoardObject]
    /// Comments created after the sync point, oldest first.
    public var newComments: [BoardComment]
    /// Where the next page of updated objects starts; nil when there is none.
    public var nextObjectCursor: BoardCursor?
    /// Where the next page of new comments starts; nil when there is none.
    public var nextCommentCursor: BoardCursor?

    public init(
        identity: BoardIdentity,
        updatedObjects: [BoardObject],
        newComments: [BoardComment],
        nextObjectCursor: BoardCursor? = nil,
        nextCommentCursor: BoardCursor? = nil
    ) {
        self.identity = identity
        self.updatedObjects = updatedObjects
        self.newComments = newComments
        self.nextObjectCursor = nextObjectCursor
        self.nextCommentCursor = nextCommentCursor
    }
}

/// One comment on a board object, as the board reported it.
public struct BoardComment: Equatable, Sendable {
    public var id: BoardObjectID
    /// The board object the comment is on.
    public var issue: BoardObjectID
    /// The human identifier of that object, such as `ENG-123`.
    public var issueKey: String
    /// That object's workflow state at the time of the read.
    public var issueWorkflowState: BoardWorkflowState
    public var body: String
    /// The comment this one is a threaded reply to; nil for a top-level comment. Recognising an
    /// answer is structural (G-8): a reply whose parent is Yellowhammer's question comment.
    public var parent: BoardObjectID?
    public var author: BoardCommentAuthor
    public var createdAt: Date

    public init(
        id: BoardObjectID,
        issue: BoardObjectID,
        issueKey: String,
        issueWorkflowState: BoardWorkflowState,
        body: String,
        parent: BoardObjectID?,
        author: BoardCommentAuthor,
        createdAt: Date
    ) {
        self.id = id
        self.issue = issue
        self.issueKey = issueKey
        self.issueWorkflowState = issueWorkflowState
        self.body = body
        self.parent = parent
        self.author = author
        self.createdAt = createdAt
    }
}

/// Who wrote a comment. `isYellowhammer` is the board's own word that the author is the identity
/// Yellowhammer authenticates as; the Engine also matches `id` against ``BoardIdentity`` so that a
/// board which cannot say so still has its self-comments filtered.
public struct BoardCommentAuthor: Hashable, Sendable {
    /// Nil when the board reports no author, such as a comment written by an integration it cannot name.
    public var id: BoardObjectID?
    public var name: String
    public var isYellowhammer: Bool

    public init(id: BoardObjectID?, name: String, isYellowhammer: Bool) {
        self.id = id
        self.name = name
        self.isYellowhammer = isYellowhammer
    }
}
