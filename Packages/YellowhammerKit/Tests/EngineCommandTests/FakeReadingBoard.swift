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
        /// The updated-issues root's `since`.
        var since: Date?
        /// The new-comments root's `since`.
        var commentsSince: Date?
        var objectsAfter: BoardCursor?
        var commentsAfter: BoardCursor?
        var pageSize: Int
        /// The request left that root out: it was read to its last page already.
        var skippedObjects = false
        var skippedComments = false
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

    /// A board with nothing to report to `reads` Delta Reads, for an Act that must read the board before it
    /// decides (roadmap P22.3) but whose test is about something else.
    static func quiet(_ reads: Int = 1) -> FakeReadingBoard {
        FakeReadingBoard(Array(repeating: page(), count: reads))
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

    private var issueReadAction: (number: Int, perform: @Sendable () -> Void)?
    private var issueReads = 0

    func onIssueRead(number: Int, perform: @escaping @Sendable () -> Void) {
        issueReadAction = (number, perform)
    }

    func issue(_ id: BoardObjectID) async throws(BoardError) -> BoardObject? {
        issueReads += 1
        if let action = issueReadAction, action.number == issueReads {
            issueReadAction = nil
            action.perform()
        }
        if let link = writeThrough, let found = await link.board.issue(id) {
            return BoardObject(
                id: found.id, key: found.id.rawValue, title: found.title, description: found.description,
                workflowState: link.states.first { $0.id == found.workflowState }
                    ?? BoardWorkflowState(id: BoardObjectID(rawValue: "todo"), name: "Todo"),
                labels: [], parent: found.parent, url: "https://linear.app/issue/\(id.rawValue)",
                createdAt: found.updatedAt, updatedAt: found.updatedAt,
                archivedAt: found.archived ? found.updatedAt : nil
            )
        }
        return seededIssues[id]
    }

    func deltaRead(
        objects: BoardRootRead, comments: BoardRootRead, pageSize: Int
    ) async throws(BoardError) -> BoardDelta {
        var call = Call(pageSize: pageSize)
        if case .page(let since, let after) = objects {
            call.since = since
            call.objectsAfter = after
        } else {
            call.skippedObjects = true
        }
        if case .page(let since, let after) = comments {
            call.commentsSince = since
            call.commentsAfter = after
        } else {
            call.skippedComments = true
        }
        calls.append(call)
        guard !replies.isEmpty else { throw .unreachable("no scripted reply") }
        switch replies.removeFirst() {
        case .success(var delta):
            // A root the request skipped answers nothing, whatever the script holds for it.
            if call.skippedObjects {
                delta.updatedObjects = []
                delta.nextObjectCursor = nil
            }
            if call.skippedComments {
                delta.newComments = []
                delta.nextCommentCursor = nil
            }
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

    /// Scripted ``identity()`` outcome (roadmap P17.5: the Act's authorization preflight is its first
    /// call) — success unless a test configures otherwise.
    var identityResult: Result<BoardIdentity, BoardError> = .success(FakeReadingBoard.identity)
    private(set) var identityCalls = 0

    func script(identity result: Result<BoardIdentity, BoardError>) {
        identityResult = result
    }

    func identity() async throws(BoardError) -> BoardIdentity {
        identityCalls += 1
        switch identityResult {
        case .success(let identity): return identity
        case .failure(let error): throw error
        }
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
