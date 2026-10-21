import Domain
import Foundation
import Journal

/// What the Engine needs from a Project's own record of its board footprint (board-projection/
/// provision-the-board, P22.8): the ids persisted by earlier provisioning, a place to record new ones, and
/// the one provenance question that lets an already-provisioned board be adopted without a mapping.
///
/// ``JournalStore`` is the production conformance. Tests substitute an in-memory one, so the idempotency
/// of provisioning (a second run sees the first run's ids) is assertable without a Journal file.
public protocol BoardFootprintStore: Sendable {
    func persistedFootprint() throws -> [BoardFootprintRecord]
    func recordFootprint(_ records: [BoardFootprintRecord]) throws
    /// True when Yellowhammer itself delivered a write that set `stateID` as an issue's workflow state.
    func hasDeliveredStateWrite(to stateID: BoardObjectID) throws -> Bool
}

extension JournalStore: BoardFootprintStore {
    public func persistedFootprint() throws -> [BoardFootprintRecord] { try boardFootprint() }

    public func recordFootprint(_ records: [BoardFootprintRecord]) throws { try recordBoardFootprint(records) }

    public func hasDeliveredStateWrite(to stateID: BoardObjectID) throws -> Bool {
        try hasDeliveredStateWrite(stateID: stateID)
    }
}

/// An in-memory ``BoardFootprintStore``: for a run with no Journal to read (`yh doctor` before a Project's
/// first Act) and for tests. Holds whatever it was given and records into itself.
public final class InMemoryBoardFootprintStore: BoardFootprintStore, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [BoardFootprintRecord]
    private let deliveredStates: Set<BoardObjectID>

    public init(records: [BoardFootprintRecord] = [], deliveredStateWrites: Set<BoardObjectID> = []) {
        self.records = records
        self.deliveredStates = deliveredStateWrites
    }

    public func persistedFootprint() throws -> [BoardFootprintRecord] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }

    public func recordFootprint(_ new: [BoardFootprintRecord]) throws {
        lock.lock()
        defer { lock.unlock() }
        for record in new {
            records.removeAll { $0.team == record.team && $0.role == record.role }
            records.append(record)
        }
    }

    public func hasDeliveredStateWrite(to stateID: BoardObjectID) throws -> Bool {
        deliveredStates.contains(stateID)
    }
}

/// What a provisioning or verification run reads about the footprint: the Project's Board Mapping and the
/// store holding persisted ids and provenance. ``none`` is a run with neither (an empty mapping, no ids).
public struct BoardFootprintInputs: Sendable {
    public var mapping: BoardMapping
    public var store: (any BoardFootprintStore)?

    public init(mapping: BoardMapping = .empty, store: (any BoardFootprintStore)? = nil) {
        self.mapping = mapping
        self.store = store
    }

    public static let none = BoardFootprintInputs()
}
