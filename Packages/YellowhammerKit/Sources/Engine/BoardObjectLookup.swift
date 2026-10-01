import Domain
import Foundation

/// Finds board objects by id with the Board Port's only read, paging `board.reading.objects` up to a
/// bounded number of pages. The Port has no read-by-id (ADR-001); this is the best a Port-only read
/// offers. A page read that fails ends the search with whatever was found.
enum BoardObjectLookup {
    static let pageBound = 10

    /// Every object among `ids` the board returned, keyed by the id asked for (matched on `key` or
    /// `id.rawValue`). Stops early once all are found.
    static func find(ids: Set<String>, board: ActBoard?) async -> [String: BoardObject] {
        guard let board, !ids.isEmpty else { return [:] }
        var found: [String: BoardObject] = [:]
        var cursor: BoardCursor?
        for _ in 0..<pageBound {
            guard
                let page = try? await board.reading.objects(updatedSince: nil, after: cursor, pageSize: 200)
            else {
                return found
            }
            for object in page.objects {
                for id in ids where found[id] == nil && (object.key == id || object.id.rawValue == id) {
                    found[id] = object
                }
            }
            if found.count == ids.count { return found }
            guard let next = page.nextCursor else { return found }
            cursor = next
        }
        return found
    }
}
