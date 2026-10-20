import Domain
import Foundation
import Journal

// The Delta Read's paging, deduplication and cursors (spec: board-projection / read-board-changes-by-delta,
// `sync-boundary`), split out of DeltaRead.swift to keep that file under the type-length limit.
//
// Each root of the compound query — updated issues, new comments — is paged by its own `pageInfo` and
// never requested again once its last page is in. Each has its own cursor, so a comment newer than an
// unread issue change cannot move the issues' cursor past it. Both boundaries are inclusive and the cursor
// is held `syncOverlap` behind the sync horizon, so what is read twice is deduplicated by issue id and
// `updatedAt`, and by comment id, from observations stored in the Journal. Nothing is applied until the
// last page of both roots is in, and the cursors move in the same transaction that stores the
// observations, so an interruption anywhere leaves them where they were and the retry is idempotent.

/// Everything the pages of one read carried, before it is deduplicated.
struct DeltaPages {
    var objects: [BoardObject]
    var comments: [BoardComment]
    var identity: BoardIdentity
    var requests: Int
}

/// The pages of one read, deduplicated within themselves (`observed`) and against what the Journal already
/// observed (`fresh`): the overlap a cursor deliberately re-reads lands in the difference.
struct DeltaObservations {
    var objects: [BoardObject]
    var comments: [BoardComment]
    var freshObjects: [BoardObject]
    var freshComments: [BoardComment]
}

/// What a completed read persists and reports about its cursors.
struct ReadPlan {
    /// The earliest of the cursors the read started from; nil for a first read. A summary for the report.
    var since: Date?
    /// The latest of the cursors after the read. A summary for the report.
    var syncPoint: Date?
    /// Nil when there is nothing to store: no new observation, no cursor to move, nothing to clear.
    var record: BoardReadRecord?
    /// Board copies the build Act replays from an earlier read (their events are already in the log).
    var replayed: Set<BoardObjectID> = []
}

extension DeltaRead {
    /// How far behind the sync horizon a cursor is held. A change that arrives while pages are being read
    /// is stamped at or after the horizon, so it is at or after the cursor and is read next time; the
    /// same margin tolerates a clock that differs from the board's by up to this much.
    static let syncOverlap: TimeInterval = 120

    /// Whether this read owns the build decisions on Cards (re-ready, the Operator's edits to a Card the
    /// build Act is about to dispatch). Any other Act's read leaves what it observed pending for the build Act.
    var ownsBuildDecisions: Bool {
        act == nil || act == .build
    }

    /// Reads every page of both roots since each root's own cursor, then reconciles and records. Nothing
    /// is applied to the Journal until the last page is in, so a refusal half-way leaves no partial
    /// reconciliation, and the cursors do not move.
    public func perform() async throws -> DeltaReadOutcome {
        let started = horizon()
        let sync = try journal.boardSyncPoint()

        var issuesRoot = BoardRootRead.page(since: sync?.issuesSynced, after: nil)
        var commentsRoot = BoardRootRead.page(since: sync?.commentsSynced, after: nil)
        var objects: [BoardObject] = []
        var comments: [BoardComment] = []
        var identity: BoardIdentity?
        var requests = 0

        while issuesRoot != .skip || commentsRoot != .skip {
            if requests >= requestLimit {
                return try incomplete(requests: requests)
            }
            let delta: BoardDelta
            do {
                delta = try await board.deltaRead(objects: issuesRoot, comments: commentsRoot, pageSize: pageSize)
            } catch BoardError.rateLimited(let retryAfter, _) {
                return try degrade(requests: requests + 1, retryAfter: retryAfter)
            } catch {
                throw DeltaReadError.boardUnavailable(error)
            }
            requests += 1
            identity = delta.identity
            objects += delta.updatedObjects
            comments += delta.newComments
            issuesRoot = Self.nextPage(of: issuesRoot, cursor: delta.nextObjectCursor)
            commentsRoot = Self.nextPage(of: commentsRoot, cursor: delta.nextCommentCursor)
        }

        guard let identity else { return try incomplete(requests: requests) }
        let pages = DeltaPages(objects: objects, comments: comments, identity: identity, requests: requests)
        return .read(try complete(pages, since: sync, started: started))
    }

    /// A root with another page is resumed after its cursor; one that has none is done and is not asked for again.
    private static func nextPage(of root: BoardRootRead, cursor: BoardCursor?) -> BoardRootRead {
        guard case .page(let since, _) = root, let cursor else { return .skip }
        return .page(since: since, after: cursor)
    }

    private func degrade(requests: Int, retryAfter: Duration?) throws -> DeltaReadOutcome {
        var reason = "the Delta Read was refused for the rate budget after \(requests) request(s); "
            + "nothing read this Act is acted on and the sync point is unchanged"
        if let retryAfter {
            reason += "; retry after \(retryAfter)"
        }
        try append(.rateBudgetExhausted(degradation: reason, installation: installation))
        return .degraded(reason: reason)
    }

    /// The request cap was reached before the last page: an incomplete sync. Recorded, no cursor moves,
    /// and the Act defers what depends on the observation it is missing.
    private func incomplete(requests: Int) throws -> DeltaReadOutcome {
        let reason = "the Delta Read did not reach the last page after \(requests) request(s); "
            + "nothing read this Act is acted on and no cursor moved"
        try append(.deltaReadIncomplete(requests: requests, reason: reason))
        return .degraded(reason: reason)
    }

    // MARK: - Completing

    private func complete(_ pages: DeltaPages, since sync: BoardSyncPoint?, started: Date) throws -> DeltaReadReport {
        let observed = Self.latestRevisions(pages.objects)
        let observedComments = Self.distinct(pages.comments)

        // Deduplicate against what the Journal already observed: an issue by id and `updatedAt` revision,
        // a comment by id. The overlap a cursor deliberately re-reads lands here and is dropped.
        let revisions = try journal.observedIssueRevisions(observed.map(\.id.rawValue))
        let seenComments = try journal.observedCommentIDs(observedComments.map(\.id.rawValue))
        let observations = DeltaObservations(
            objects: observed, comments: observedComments,
            freshObjects: observed.filter { object in
                guard let seen = revisions[object.id.rawValue] else { return true }
                return seen < object.updatedAt
            },
            freshComments: observedComments.filter { !seenComments.contains($0.id.rawValue) }
        )

        // The build Act also reconciles what an earlier author or land read observed and left for it.
        let replays = ownsBuildDecisions
            ? try pendingBuildObservations(excluding: Set(observations.freshObjects.map(\.id))) : []
        let clearsPending = ownsBuildDecisions ? !(try journal.buildPendingObservations().isEmpty) : false
        var plan = try Self.plan(
            since: sync, started: started, observations, leavesBuildPending: !ownsBuildDecisions,
            clearsBuildPending: clearsPending
        )
        plan.replayed = Set(replays.map(\.id))
        return try reconcile(
            objects: observations.freshObjects + replays, comments: observations.freshComments,
            identity: pages.identity, plan: plan, requests: pages.requests
        )
    }

    /// The board copies a non-build read left pending, for the Cards of the Cycle in flight: the only
    /// Cards a build Act can still act on. A revision the delta carries again is the delta's, not a replay.
    private func pendingBuildObservations(excluding delta: Set<BoardObjectID>) throws -> [BoardObject] {
        let pending = try journal.buildPendingObservations()
        guard !pending.isEmpty, let (_, cycleID) = try journal.inFlightFeature() else { return [] }
        let inCycle = Set(try journal.cards(cycleID: cycleID).map(\.issueID))
        let decoder = JSONDecoder()
        return pending.compactMap { observation in
            guard inCycle.contains(observation.issueID),
                  !delta.contains(BoardObjectID(rawValue: observation.issueID)) else { return nil }
            return try? decoder.decode(BoardObject.self, from: Data(observation.payload.utf8))
        }
    }

    /// Several pages can carry the same issue when it changed while the pages were being read: the latest revision wins.
    private static func latestRevisions(_ objects: [BoardObject]) -> [BoardObject] {
        var latest: [BoardObjectID: BoardObject] = [:]
        var order: [BoardObjectID] = []
        for object in objects {
            if let held = latest[object.id] {
                if object.updatedAt >= held.updatedAt { latest[object.id] = object }
            } else {
                latest[object.id] = object
                order.append(object.id)
            }
        }
        return order.compactMap { latest[$0] }
    }

    private static func distinct(_ comments: [BoardComment]) -> [BoardComment] {
        var seen: Set<BoardObjectID> = []
        return comments.filter { seen.insert($0.id).inserted }
    }

    // MARK: - The plan

    /// What to persist, and the cursors it moves. A root's cursor is the latest board timestamp observed in
    /// it, held at most `syncOverlap` behind the sync horizon, and never moves backwards. A root that
    /// observed nothing keeps its cursor.
    static func plan(
        since sync: BoardSyncPoint?, started: Date, _ seen: DeltaObservations, leavesBuildPending: Bool,
        clearsBuildPending: Bool
    ) throws -> ReadPlan {
        let ceiling = started.addingTimeInterval(-syncOverlap)
        let issuesCursor = seen.objects.map(\.updatedAt).max().map { min($0, ceiling) }
        let commentsCursor = seen.comments.map(\.createdAt).max().map { min($0, ceiling) }

        let issuesAfter = later(issuesCursor, sync?.issuesSynced)
        let commentsAfter = later(commentsCursor, sync?.commentsSynced)
        let moves = issuesAfter != sync?.issuesSynced || commentsAfter != sync?.commentsSynced
        let before = [sync?.issuesSynced, sync?.commentsSynced].compactMap { $0 }.min()
        let after = later(issuesAfter, commentsAfter)

        guard moves || !seen.freshObjects.isEmpty || !seen.freshComments.isEmpty || clearsBuildPending else {
            return ReadPlan(since: before, syncPoint: after, record: nil)
        }
        let encoder = JSONEncoder()
        let observations = try seen.freshObjects.map { object in
            BoardIssueObservation(
                issueID: object.id.rawValue, updatedAt: object.updatedAt,
                payload: String(bytes: try encoder.encode(object), encoding: .utf8) ?? "{}"
            )
        }
        let cursors = [issuesAfter, commentsAfter].compactMap { $0 }
        let record = BoardReadRecord(
            issuesSynced: issuesCursor, commentsSynced: commentsCursor, issues: observations,
            comments: seen.freshComments.map {
                BoardCommentObservation(commentID: $0.id.rawValue, createdAt: $0.createdAt)
            },
            leavesBuildPending: leavesBuildPending, clearsBuildPending: clearsBuildPending,
            forgetsBefore: cursors.min().map { $0.addingTimeInterval(-86_400) }
        )
        return ReadPlan(since: before, syncPoint: after, record: record)
    }

    private static func later(_ new: Date?, _ old: Date?) -> Date? {
        switch (new, old) {
        case (let new?, let old?): max(new, old)
        case (let new?, nil): new
        case (nil, let old): old
        }
    }
}
