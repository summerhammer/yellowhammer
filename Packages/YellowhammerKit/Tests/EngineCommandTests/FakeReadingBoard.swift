import Domain
import Foundation

/// An in-memory board for the reading half of the Port: plays back scripted Delta Read replies in
/// order and records every call, so a test can see what one Act asked for.
///
/// Unlinked, a scripted page is blind to the Act's own writes: a test where the Operator changes a Card
/// on the board still reads that change even when the Engine overwrote it first. Linked through
/// ``readThrough(_:states:)``, every scripted object is the board as the Operator left it, and each write
/// the Engine made through the ``FakeWritingBoard`` after linking lands on top of it, as it would on
/// Linear, before the Delta Read sees it.
actor FakeReadingBoard: Board {
    static let identity = BoardIdentity(id: BoardObjectID(rawValue: "yellowhammer-app"), name: "Yellowhammer")

    struct Call: Equatable, Sendable {
        var since: Date?
        var objectsAfter: BoardCursor?
        var commentsAfter: BoardCursor?
        var pageSize: Int
    }

    private var replies: [Result<BoardDelta, BoardError>]
    private var objectReplies: [Result<BoardPage, BoardError>] = []
    private(set) var calls: [Call] = []
    var latestBudget: BoardBudget?
    /// Seeded for ``issue(_:)`` (the settle gesture's single-issue read, roadmap P10.9) — kept
    /// separate from `replies`/`objects`, which every existing caller of this fake still expects empty.
    private var seededIssues: [BoardObjectID: BoardObject] = [:]

    /// The writing board whose later writes overlay every scripted object, with the log length at the
    /// moment of linking and the team's workflow states to name a written state id by.
    private var writeThrough: WriteThrough?

    private struct WriteThrough {
        let board: FakeWritingBoard
        let baseline: Int
        let states: [BoardWorkflowState]
    }

    init(_ replies: [Result<BoardDelta, BoardError>]) {
        self.replies = replies
    }

    /// Seeds `object` for a later ``issue(_:)`` call, keyed by its id.
    func seed(issue object: BoardObject) {
        seededIssues[object.id] = object
    }

    /// Links this board to `writing`: from now on, every write the Engine makes to an issue through it
    /// overlays that issue on each scripted page — its workflow state (named from `states`), its
    /// description, and its archiving. Everything scripted stands for what the board held before.
    func readThrough(_ writing: FakeWritingBoard, states: [BoardWorkflowState]) async {
        writeThrough = WriteThrough(board: writing, baseline: await writing.writeLog.count, states: states)
    }

    /// Links this board to `boards.writing`, naming states from `team` on `boards.provisioning`.
    func readThrough(_ boards: NightCardTestBoards, team: BoardObjectID = teamID) async throws {
        await readThrough(boards.writing, states: try await boards.provisioning.workflowStates(team: team))
    }

    func scriptObjectPages(_ replies: [Result<BoardPage, BoardError>]) {
        objectReplies = replies
    }

    func issue(_ id: BoardObjectID) async throws(BoardError) -> BoardObject? {
        seededIssues[id]
    }

    func deltaRead(
        since: Date?, objectsAfter: BoardCursor?, commentsAfter: BoardCursor?, pageSize: Int
    ) async throws(BoardError) -> BoardDelta {
        calls.append(Call(since: since, objectsAfter: objectsAfter, commentsAfter: commentsAfter, pageSize: pageSize))
        guard !replies.isEmpty else { throw .unreachable("no scripted reply") }
        switch replies.removeFirst() {
        case .success(var delta):
            delta.updatedObjects = await overlaid(delta.updatedObjects)
            return delta
        case .failure(let error): throw error
        }
    }

    func objects(updatedSince: Date?, after: BoardCursor?, pageSize: Int) async throws(BoardError) -> BoardPage {
        guard !objectReplies.isEmpty else { return BoardPage(objects: [], nextCursor: nil) }
        switch objectReplies.removeFirst() {
        case .success(var page):
            page.objects = await overlaid(page.objects)
            return page
        case .failure(let error): throw error
        }
    }

    /// `objects` with every write the linked writing board applied since linking, in order.
    private func overlaid(_ objects: [BoardObject]) async -> [BoardObject] {
        guard let link = writeThrough else { return objects }
        let log = await link.board.writeLog.dropFirst(link.baseline)
        return objects.map { object in
            var object = object
            for entry in log where entry.issue == object.id {
                switch entry.write {
                case .update(let change):
                    if let state = change.workflowState {
                        object.workflowState = link.states.first { $0.id == state }
                            ?? BoardWorkflowState(id: state, name: state.rawValue)
                    }
                    if let description = change.description { object.description = description }
                case .archive:
                    object.archivedAt = object.archivedAt ?? object.updatedAt
                }
            }
            return object
        }
    }

    func identity() async throws(BoardError) -> BoardIdentity {
        Self.identity
    }

    /// Scripted ``isActiveMember(_:)`` outcome (roadmap P11.1, OQ66): active unless a test configures
    /// otherwise.
    var activeMemberResult: Result<Bool, BoardError> = .success(true)
    private(set) var activeMemberCalls: [BoardObjectID] = []

    func script(activeMember result: Result<Bool, BoardError>) {
        activeMemberResult = result
    }

    func isActiveMember(_ user: BoardObjectID) async throws(BoardError) -> Bool {
        activeMemberCalls.append(user)
        switch activeMemberResult {
        case .success(let value): return value
        case .failure(let error): throw error
        }
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
