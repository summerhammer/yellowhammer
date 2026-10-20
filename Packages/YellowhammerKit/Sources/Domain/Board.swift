import Foundation

/// The Board Port (ADR-001): how Yellowhammer reads the board that owns intent.
///
/// An implementation is bound to exactly one Project's Linear project when it is constructed, so no
/// call can read outside that scope. Several Projects may share a team; the Linear project is the
/// boundary.
///
/// The Port is not the policy. The Outbox, revalidating the Lease before every write, and scheduling
/// delta reads sit above it; an implementation translates and never decides.
public protocol Board: Sendable {
    /// Board objects in this Project's Linear project, ordered by last update, updated after
    /// `updatedSince` when it is given.
    func objects(updatedSince: Date?, after: BoardCursor?, pageSize: Int) async throws(BoardError) -> BoardPage

    /// One page of the Delta Read: board objects updated and comments created at or after each root's own
    /// `since`, in this Project's Linear project, from **one** request. A `since` of nil reads that root
    /// from the beginning. Each root is paged on its own (spec: board-projection / read-board-changes-by-delta,
    /// `sync-boundary`): a root already read to its last page is `.skip`, so it is never requested again
    /// and costs nothing in the request. A skipped root answers an empty list and no cursor; the identity
    /// rides along in every request.
    func deltaRead(
        objects: BoardRootRead, comments: BoardRootRead, pageSize: Int
    ) async throws(BoardError) -> BoardDelta

    /// The identity the board resolves Yellowhammer's calls to — the registered application, never an Operator.
    func identity() async throws(BoardError) -> BoardIdentity

    /// One board object by id, nil when it does not exist (or is outside this Project's Linear
    /// project). The settle gesture's read of the Feature Issue's workflow state (roadmap P10.9) is
    /// the one caller that needs a single object rather than a page; the protocol extension's default
    /// pages ``objects(updatedSince:after:pageSize:)`` to find it, so an existing fake `Board` keeps
    /// compiling without implementing this itself.
    func issue(_ id: BoardObjectID) async throws(BoardError) -> BoardObject?

    /// True when `user` is an active (not deactivated) member of the workspace, false when deactivated
    /// or not found. No default implementation: every conformer decides for itself, since "not found"
    /// and "deactivated" read differently through each vendor's API (OQ66).
    func isActiveMember(_ user: BoardObjectID) async throws(BoardError) -> Bool

    /// The budget the board reported on its most recent response, nil before any response.
    var latestBudget: BoardBudget? { get async }
}

extension Board {
    /// A page of about 200 board objects is one request.
    public static var defaultPageSize: Int { 200 }

    /// Finds `id` by paging every board object (``objects(updatedSince:after:pageSize:)``, `nil`
    /// since). An implementation with a real single-issue query (``LinearAdapter``) overrides this
    /// with a targeted request instead.
    public func issue(_ id: BoardObjectID) async throws(BoardError) -> BoardObject? {
        var cursor: BoardCursor?
        repeat {
            let page = try await objects(updatedSince: nil, after: cursor, pageSize: Self.defaultPageSize)
            if let found = page.objects.first(where: { $0.id == id }) {
                return found
            }
            cursor = page.nextCursor
        } while cursor != nil
        return nil
    }

    public func objects(
        updatedSince: Date?, after: BoardCursor? = nil
    ) async throws(BoardError) -> BoardPage {
        try await objects(updatedSince: updatedSince, after: after, pageSize: Self.defaultPageSize)
    }

    /// The page size the spec's compound document names: `first: 50` on each root.
    public static var deltaPageSize: Int { 50 }

    /// Both roots from the same `since`, each resumed from its own cursor: the shape of a first request
    /// (nil cursors) and of a caller that has no per-root state.
    public func deltaRead(
        since: Date?, objectsAfter: BoardCursor? = nil, commentsAfter: BoardCursor? = nil,
        pageSize: Int = Self.deltaPageSize
    ) async throws(BoardError) -> BoardDelta {
        try await deltaRead(
            objects: .page(since: since, after: objectsAfter),
            comments: .page(since: since, after: commentsAfter),
            pageSize: pageSize
        )
    }
}

/// What one request asks of one root of the Delta Read (objects or comments).
public enum BoardRootRead: Equatable, Sendable {
    /// The root is not requested: it was read to its last page already, or is not wanted.
    case skip
    /// The root's items changed at or after `since` (inclusive: the caller deduplicates the overlap),
    /// resumed after `after` when the root has more pages.
    case page(since: Date?, after: BoardCursor?)
}

/// Who the board says Yellowhammer is.
public struct BoardIdentity: Codable, Hashable, Sendable {
    public var id: BoardObjectID
    public var name: String
    public var displayName: String?

    public init(id: BoardObjectID, name: String, displayName: String? = nil) {
        self.id = id
        self.name = name
        self.displayName = displayName
    }
}
