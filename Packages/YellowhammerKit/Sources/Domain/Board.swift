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

    /// The Delta Read: board objects updated and comments created after `since`, in this Project's
    /// Linear project, from **one** request. `since` nil reads everything. Each page of either list is
    /// resumed from its own cursor; the identity rides along in the same request.
    func deltaRead(
        since: Date?, objectsAfter: BoardCursor?, commentsAfter: BoardCursor?, pageSize: Int
    ) async throws(BoardError) -> BoardDelta

    /// The identity the board resolves Yellowhammer's calls to — the registered application, never an Operator.
    func identity() async throws(BoardError) -> BoardIdentity

    /// One board object by id, nil when it does not exist (or is outside this Project's Linear
    /// project). The settle gesture's read of the Feature Issue's workflow state (roadmap P10.9) is
    /// the one caller that needs a single object rather than a page; the protocol extension's default
    /// pages ``objects(updatedSince:after:pageSize:)`` to find it, so an existing fake `Board` keeps
    /// compiling without implementing this itself.
    func issue(_ id: BoardObjectID) async throws(BoardError) -> BoardObject?

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

    public func deltaRead(
        since: Date?, objectsAfter: BoardCursor? = nil, commentsAfter: BoardCursor? = nil
    ) async throws(BoardError) -> BoardDelta {
        try await deltaRead(
            since: since, objectsAfter: objectsAfter, commentsAfter: commentsAfter, pageSize: Self.deltaPageSize
        )
    }
}

/// Who the board says Yellowhammer is.
public struct BoardIdentity: Hashable, Sendable {
    public var id: BoardObjectID
    public var name: String

    public init(id: BoardObjectID, name: String) {
        self.id = id
        self.name = name
    }
}
