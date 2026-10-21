import Domain
import Foundation
import Journal

// The Delta Read's paging, deduplication and cursors (spec: board-projection / read-board-changes-by-delta,
// `sync-boundary`), split out of DeltaRead.swift to keep that file under the type-length limit.
//
// A read that hits the request cap is resumable, not sticky: it applies and stores what its pages carried,
// checkpoints each unfinished root's `endCursor` with the `since` and horizon the pass started with, moves no
// time cursor, and reports itself incomplete. The next Act resumes each root from its checkpoint and, once
// every root is done, moves the cursors exactly as a one-Act read would (horizon of the pass that started it).
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
    /// The pass this read belongs to: its horizon, each root's `since`, resume point and latest observation.
    var pass: BoardReadPass
    /// Every root reached its last page; otherwise the request cap stopped the read and `pass` is checkpointed.
    var finished: Bool
}

/// The pages of one read, deduplicated within themselves (`observed`) and against what the Journal already
/// observed (`fresh`): the overlap a cursor deliberately re-reads lands in the difference.
struct DeltaObservations {
    var objects: [BoardObject]
    var comments: [BoardComment]
    var freshObjects: [BoardObject]
    var freshComments: [BoardComment]
    var pass: BoardReadPass
    var finished: Bool
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
    /// False for the partial read of an over-cap pass: it is reconciled, but not reported as a completed read.
    var completes = true
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

    /// Reads every page of both roots since each root's own cursor (or resumes the checkpointed pass), then
    /// reconciles and records. Nothing is applied until the last page is in, so a refusal half-way leaves no
    /// partial reconciliation and no cursor moved. At the request cap what was read is applied, the pass is
    /// checkpointed and the outcome is `.degraded`.
    public func perform() async throws -> DeltaReadOutcome {
        let sync = try journal.boardSyncPoint()
        let resumed = sync?.pass
        var pass = resumed ?? BoardReadPass(
            horizon: horizon(), issues: BoardPassRoot(since: sync?.issuesSynced),
            comments: BoardPassRoot(since: sync?.commentsSynced)
        )
        var objects: [BoardObject] = []
        var comments: [BoardComment] = []
        var identity: BoardIdentity?
        var requests = 0
        var restarted = false

        while !pass.issues.done || !pass.comments.done {
            if requests >= requestLimit { break }
            let delta: BoardDelta
            do {
                delta = try await board.deltaRead(
                    objects: Self.request(pass.issues), comments: Self.request(pass.comments), pageSize: pageSize
                )
            } catch BoardError.rateLimited(let retryAfter, _) {
                return try degrade(requests: requests + 1, retryAfter: retryAfter)
            } catch BoardError.refused where requests == 0 && !restarted && resumed != nil {
                // The board refused a checkpointed `endCursor` as stale: restart the unfinished roots from
                // their `since`. What the lost pages carried was stored already, and dedup makes the re-read safe.
                pass.issues.after = nil
                pass.comments.after = nil
                restarted = true
                try append(.deltaReadIncomplete(
                    requests: 1, reason: "the board refused the checkpointed page cursor; "
                        + "the unfinished roots restart from their time cursor"
                ))
                continue
            } catch {
                throw DeltaReadError.boardUnavailable(error)
            }
            requests += 1
            identity = delta.identity
            objects += delta.updatedObjects
            comments += delta.newComments
            Self.advance(&pass.issues, cursor: delta.nextObjectCursor, observed: delta.updatedObjects.map(\.updatedAt))
            Self.advance(&pass.comments, cursor: delta.nextCommentCursor, observed: delta.newComments.map(\.createdAt))
        }

        guard let identity else { return try incomplete(requests: requests) }
        let finished = pass.issues.done && pass.comments.done
        let pages = DeltaPages(
            objects: objects, comments: comments, identity: identity, requests: requests, pass: pass,
            finished: finished
        )
        let report = try complete(pages, since: sync)
        return finished ? .read(report) : try incomplete(requests: requests)
    }

    /// What one request asks of a root: nothing once it is done, else its page after the checkpoint.
    private static func request(_ root: BoardPassRoot) -> BoardRootRead {
        root.done ? .skip : .page(since: root.since, after: root.after.map(BoardCursor.init(rawValue:)))
    }

    /// Takes a root past the page just read: to its next cursor, or to done when it had none.
    private static func advance(_ root: inout BoardPassRoot, cursor: BoardCursor?, observed: [Date]) {
        guard !root.done else { return }
        root.maxObserved = later(observed.max(), root.maxObserved)
        root.after = cursor?.rawValue
        root.done = cursor == nil
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

    /// The request cap was reached before the last page: an incomplete sync. Recorded; the pass is
    /// checkpointed, no time cursor moves, and the Act defers what depends on the observation it is missing.
    private func incomplete(requests: Int) throws -> DeltaReadOutcome {
        let reason = "the Delta Read did not reach the last page after \(requests) request(s); the next Act "
            + "resumes it from its checkpoint, and no cursor moves until it completes"
        try append(.deltaReadIncomplete(requests: requests, reason: reason))
        return .degraded(reason: reason)
    }

    // MARK: - Completing

    private func complete(_ pages: DeltaPages, since sync: BoardSyncPoint?) throws -> DeltaReadReport {
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
            freshComments: observedComments.filter { !seenComments.contains($0.id.rawValue) },
            pass: pages.pass, finished: pages.finished
        )

        // The build Act also reconciles what an earlier author or land read observed and left for it.
        let replays = ownsBuildDecisions
            ? try pendingBuildObservations(excluding: Set(observations.freshObjects.map(\.id))) : []
        let clearsPending = ownsBuildDecisions ? !(try journal.buildPendingObservations().isEmpty) : false
        var plan = try Self.plan(
            since: sync, observations, leavesBuildPending: !ownsBuildDecisions, clearsBuildPending: clearsPending
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
                if object.updatedAt > held.updatedAt { latest[object.id] = object }
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
        since sync: BoardSyncPoint?, _ seen: DeltaObservations, leavesBuildPending: Bool, clearsBuildPending: Bool
    ) throws -> ReadPlan {
        // Cursors move only when the pass is finished, from the horizon of the read that started it.
        let ceiling = seen.pass.horizon.addingTimeInterval(-syncOverlap)
        let issuesCursor = seen.finished ? seen.pass.issues.maxObserved.map { min($0, ceiling) } : nil
        let commentsCursor = seen.finished ? seen.pass.comments.maxObserved.map { min($0, ceiling) } : nil

        let issuesAfter = later(issuesCursor, sync?.issuesSynced)
        let commentsAfter = later(commentsCursor, sync?.commentsSynced)
        let moves = issuesAfter != sync?.issuesSynced || commentsAfter != sync?.commentsSynced
        let before = [sync?.issuesSynced, sync?.commentsSynced].compactMap { $0 }.min()
        let after = later(issuesAfter, commentsAfter)

        let endsPass = seen.finished && sync?.pass != nil
        guard moves || !seen.freshObjects.isEmpty || !seen.freshComments.isEmpty || clearsBuildPending
            || endsPass || !seen.finished
        else {
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
            forgetsBefore: cursors.min().map { $0.addingTimeInterval(-86_400) },
            pass: seen.finished ? .clear : .set(seen.pass)
        )
        return ReadPlan(since: before, syncPoint: after, record: record, completes: seen.finished)
    }

    static func later(_ new: Date?, _ old: Date?) -> Date? {
        switch (new, old) {
        case (let new?, let old?): max(new, old)
        case (let new?, nil): new
        case (nil, let old): old
        }
    }
}
