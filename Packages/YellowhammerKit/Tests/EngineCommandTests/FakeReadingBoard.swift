import Domain
import Foundation

/// An in-memory board for the reading half of the Port: plays back scripted Delta Read replies in
/// order and records every call, so a test can see what one Act asked for.
actor FakeReadingBoard: Board {
    static let identity = BoardIdentity(id: BoardObjectID(rawValue: "yellowhammer-app"), name: "Yellowhammer")

    struct Call: Equatable, Sendable {
        var since: Date?
        var objectsAfter: BoardCursor?
        var commentsAfter: BoardCursor?
        var pageSize: Int
    }

    private var replies: [Result<BoardDelta, BoardError>]
    private(set) var calls: [Call] = []
    var latestBudget: BoardBudget?

    init(_ replies: [Result<BoardDelta, BoardError>]) {
        self.replies = replies
    }

    func deltaRead(
        since: Date?, objectsAfter: BoardCursor?, commentsAfter: BoardCursor?, pageSize: Int
    ) async throws(BoardError) -> BoardDelta {
        calls.append(Call(since: since, objectsAfter: objectsAfter, commentsAfter: commentsAfter, pageSize: pageSize))
        guard !replies.isEmpty else { throw .unreachable("no scripted reply") }
        switch replies.removeFirst() {
        case .success(let delta): return delta
        case .failure(let error): throw error
        }
    }

    func objects(updatedSince: Date?, after: BoardCursor?, pageSize: Int) async throws(BoardError) -> BoardPage {
        BoardPage(objects: [], nextCursor: nil)
    }

    func identity() async throws(BoardError) -> BoardIdentity {
        Self.identity
    }
}

/// A reply carrying these objects and comments, with no further page unless a cursor is given.
func page(
    objects: [BoardObject] = [], comments: [BoardComment] = [],
    nextObjectCursor: BoardCursor? = nil, nextCommentCursor: BoardCursor? = nil
) -> Result<BoardDelta, BoardError> {
    .success(BoardDelta(
        identity: FakeReadingBoard.identity, updatedObjects: objects, newComments: comments,
        nextObjectCursor: nextObjectCursor, nextCommentCursor: nextCommentCursor
    ))
}
