import Domain
import Foundation
import Journal

/// What the Engine needs from a Project's own record of its board footprint (board-projection/
/// provision-the-board, P22.8): the ids persisted by earlier provisioning and a place to record new ones.
///
/// ``JournalStore`` is the production conformance. Tests substitute an in-memory one, so the idempotency
/// of provisioning (a second run sees the first run's ids) is assertable without a Journal file.
public protocol BoardFootprintStore: Sendable {
    func persistedFootprint() throws -> [BoardFootprintRecord]
    func recordFootprint(_ records: [BoardFootprintRecord]) throws
}

extension JournalStore: BoardFootprintStore {
    public func persistedFootprint() throws -> [BoardFootprintRecord] { try boardFootprint() }

    public func recordFootprint(_ records: [BoardFootprintRecord]) throws { try recordBoardFootprint(records) }
}

/// An in-memory ``BoardFootprintStore``: for a run with no Journal to read (`yh doctor` before a Project's
/// first Act) and for tests. Holds whatever it was given and records into itself.
public final class InMemoryBoardFootprintStore: BoardFootprintStore, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [BoardFootprintRecord]

    public init(records: [BoardFootprintRecord] = []) {
        self.records = records
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
}

/// What a provisioning or verification run reads about the footprint: the Project's Board Mapping and the
/// store holding persisted ids. ``none`` is a run with neither (an empty mapping, no ids).
public struct BoardFootprintInputs: Sendable {
    public var mapping: BoardMapping
    public var store: (any BoardFootprintStore)?

    public init(mapping: BoardMapping = .empty, store: (any BoardFootprintStore)? = nil) {
        self.mapping = mapping
        self.store = store
    }

    public static let none = BoardFootprintInputs()
}
