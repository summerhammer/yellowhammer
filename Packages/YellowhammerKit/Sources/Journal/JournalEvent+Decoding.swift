import Domain
import Foundation

extension JournalEvent {
    /// Decodes an event from its type and payload. Throws `JournalError.eventUnreadable(id:)` with
    /// the row id if the payload is malformed for this type.
    init(type: JournalEventType, payload: [String: String]?, rowID: Int64) throws {
        let reader = PayloadReader(payload: payload, rowID: rowID)
        self = try Self.decode(type: type, reader: reader)
    }

    // One exhaustive switch over the event vocabulary: a case per type is the whole of its
    // complexity, and the compiler's exhaustiveness check is what keeps the decoder in step
    // with the enum.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    fileprivate static func decode(
        type: JournalEventType,
        reader: PayloadReader
    ) throws -> JournalEvent {
        switch type {
        case .actStarted:
            .actStarted
        case .actEnded:
            .actEnded
        case .actIdle:
            try Self.decodeActIdle(reader)
        case .actIncomplete:
            .actIncomplete(reason: try reader.require("reason"))
        case .actStoodDown:
            try Self.decodeStoodDown(reader)
        case .mainlineFetchFailed:
            .mainlineFetchFailed(
                repository: try reader.require("repository"),
                reason: try reader.require("reason")
            )
        case .absentNightDetected:
            .absentNightDetected(nightStart: try reader.nightStart("night_start"))
        case .authoringNoWorkAvailable:
            .authoringNoWorkAvailable
        case .managedBlockDelimiterBroken:
            .managedBlockDelimiterBroken(issueID: try reader.require("issue_id"))
        case .notificationDeliveryFailed:
            .notificationDeliveryFailed(
                notification: try reader.require("notification"),
                reason: try reader.require("reason")
            )
        case .rateBudgetExhausted:
            .rateBudgetExhausted(degradation: try reader.require("degradation"))
        case .leaseReclaimed:
            try Self.decodeLeaseReclaimed(reader)
        case .cardLeaseReclaimed:
            try Self.decodeCardLeaseReclaimed(reader)
        case .nightOpened:
            .nightOpened
        case .nightClosed:
            try Self.decodeNightClosed(reader)
        case .nightOpenedAndDied:
            try Self.decodeNightOpenedAndDied(reader)
        case .managedBlockWritten:
            try Self.decodeManagedBlockWritten(reader)
        case .nightCardOpened:
            .nightCardOpened(issueID: try reader.require("issue_id"))
        case .nightCardCompleted:
            .nightCardCompleted(issueID: try reader.require("issue_id"))
        case .boardWriteFailed:
            try Self.decodeBoardWriteFailed(reader)
        case .outboxGroupRolledBack:
            try Self.decodeOutboxGroupRolledBack(reader)
        case .cardCancelled:
            try Self.decodeCardCancelled(reader)
        case .cardReopened:
            try Self.decodeCardReopened(reader)
        case .cardRestated:
            try Self.decodeCardRestated(reader)
        case .cardRemovedFromBoard:
            try Self.decodeCardRemovedFromBoard(reader)
        case .authoringInvariantBroken:
            try Self.decodeAuthoringInvariantBroken(reader)
        case .deltaReadCompleted:
            try Self.decodeDeltaReadCompleted(reader)
        case .cardStateTransitioned:
            try Self.decodeCardStateTransitioned(reader)
        case .waitingOnYouUnbacked:
            try Self.decodeWaitingOnYouUnbacked(reader)
        case .worktreeLost:
            try Self.decodeWorktreeLost(reader)
        case .worktreeFenced:
            try Self.decodeWorktreeFenced(reader)
        case .worktreeNotQuiescent:
            try Self.decodeWorktreeNotQuiescent(reader)
        case .worktreeWIPCommitted:
            try Self.decodeWorktreeWIPCommitted(reader)
        case .worktreeReconciliationFailed:
            try Self.decodeWorktreeReconciliationFailed(reader)
        case .routeExhausted:
            .routeExhausted(
                cardID: try reader.int64("card_id"),
                issueID: try reader.require("issue_id"),
                reason: try reader.require("reason")
            )
        case .overrideRefused:
            .overrideRefused(
                cardID: try reader.int64("card_id"),
                issueID: try reader.require("issue_id"),
                reason: try reader.require("reason")
            )
        }
    }

    private static func decodeActIdle(_ reader: PayloadReader) throws -> JournalEvent {
        let reasonText = try reader.require("reason")
        guard let reason = ActIdleReason(rawValue: reasonText) else {
            throw JournalError.eventUnreadable(id: reader.rowID)
        }
        return .actIdle(reason: reason)
    }

    private static func decodeStoodDown(_ reader: PayloadReader) throws -> JournalEvent {
        let runID = try reader.runID("holder_run_id")
        let act = try reader.act("holder_act")
        let mode = try reader.mode("holder_mode")
        let holder = ActLease(
            act: act,
            runID: runID,
            mode: mode,
            claimedAt: try reader.date("holder_claimed_at"),
            heartbeatAt: try reader.date("holder_heartbeat_at"),
            expiresAt: try reader.date("holder_expires_at")
        )
        return .actStoodDown(holder: holder)
    }

    private static func decodeLeaseReclaimed(_ reader: PayloadReader) throws -> JournalEvent {
        let runID = try reader.runID("previous_run_id")
        let act = try reader.act("previous_act")
        let expiredAt = try reader.date("expired_at")
        return .leaseReclaimed(previousRunID: runID, previousAct: act, expiredAt: expiredAt)
    }

    private static func decodeCardLeaseReclaimed(_ reader: PayloadReader) throws -> JournalEvent {
        let cardID = try reader.int64("card_id")
        let runID = try reader.runID("previous_run_id")
        let expiredAt = try reader.date("expired_at")
        return .cardLeaseReclaimed(cardID: cardID, previousRunID: runID, expiredAt: expiredAt)
    }

    private static func decodeNightClosed(_ reader: PayloadReader) throws -> JournalEvent {
        .nightClosed(reason: try reader.closeReason("reason"))
    }

    private static func decodeNightOpenedAndDied(_ reader: PayloadReader) throws -> JournalEvent {
        .nightOpenedAndDied(
            nightID: try reader.int64("night_id"),
            nightStart: try reader.nightStart("night_start")
        )
    }

    private static func decodeManagedBlockWritten(_ reader: PayloadReader) throws -> JournalEvent {
        .managedBlockWritten(
            issueID: try reader.require("issue_id"),
            preservedProseHash: try reader.require("preserved_prose_hash"),
            renderedHash: try reader.require("rendered_hash")
        )
    }

    private static func decodeBoardWriteFailed(_ reader: PayloadReader) throws -> JournalEvent {
        .boardWriteFailed(
            clientID: try reader.uuid("client_id"),
            operation: try reader.require("operation"),
            issueID: reader.payload?["issue_id"],
            reason: try reader.require("reason")
        )
    }

    private static func decodeOutboxGroupRolledBack(_ reader: PayloadReader) throws -> JournalEvent {
        .outboxGroupRolledBack(
            groupID: try reader.require("group_id"),
            reason: try reader.require("reason")
        )
    }

    private static func decodeCardCancelled(_ reader: PayloadReader) throws -> JournalEvent {
        .cardCancelled(
            cardID: try reader.int64("card_id"),
            issueID: try reader.require("issue_id"),
            previousState: try reader.cardState("previous_state")
        )
    }

    private static func decodeCardReopened(_ reader: PayloadReader) throws -> JournalEvent {
        .cardReopened(
            cardID: try reader.int64("card_id"),
            issueID: try reader.require("issue_id"),
            restoredState: try reader.cardState("restored_state")
        )
    }

    private static func decodeCardRestated(_ reader: PayloadReader) throws -> JournalEvent {
        .cardRestated(
            cardID: try reader.int64("card_id"),
            issueID: try reader.require("issue_id"),
            journalState: try reader.cardState("journal_state"),
            boardState: try reader.require("board_state")
        )
    }

    private static func decodeCardRemovedFromBoard(_ reader: PayloadReader) throws -> JournalEvent {
        .cardRemovedFromBoard(
            cardID: try reader.int64("card_id"),
            issueID: try reader.require("issue_id"),
            how: try reader.require("how")
        )
    }

    private static func decodeAuthoringInvariantBroken(_ reader: PayloadReader) throws -> JournalEvent {
        .authoringInvariantBroken(
            cardID: try reader.int64("card_id"),
            issueID: try reader.require("issue_id"),
            reason: try reader.require("reason")
        )
    }

    private static func decodeDeltaReadCompleted(_ reader: PayloadReader) throws -> JournalEvent {
        .deltaReadCompleted(
            objects: try reader.int("objects"),
            comments: try reader.int("comments"),
            ownComments: try reader.int("own_comments"),
            requests: try reader.int("requests"),
            since: try reader.optionalDate("since"),
            syncPoint: try reader.optionalDate("sync_point")
        )
    }

    private static func decodeCardStateTransitioned(_ reader: PayloadReader) throws -> JournalEvent {
        .cardStateTransitioned(
            cardID: try reader.int64("card_id"),
            issueID: try reader.require("issue_id"),
            from: try reader.cardState("from_state"),
            to: try reader.cardState("to_state"),
            waitingReason: reader.payload?["waiting_reason"].flatMap { WaitingReason(rawValue: $0) },
            blockReason: reader.payload?["block_reason"].flatMap { BlockReason(rawValue: $0) }
        )
    }

    private static func decodeWaitingOnYouUnbacked(_ reader: PayloadReader) throws -> JournalEvent {
        .waitingOnYouUnbacked(
            issueID: try reader.require("issue_id"),
            cardID: reader.payload?["card_id"].flatMap { Int64($0) },
            reason: try reader.require("reason")
        )
    }

    private static func decodeWorktreeLost(_ reader: PayloadReader) throws -> JournalEvent {
        .worktreeLost(
            featureID: try reader.int64("feature_id"),
            repository: try reader.require("repository"),
            worktreeID: try reader.require("worktree_id"),
            path: try reader.require("path")
        )
    }

    private static func decodeWorktreeFenced(_ reader: PayloadReader) throws -> JournalEvent {
        .worktreeFenced(
            featureID: try reader.int64("feature_id"),
            repository: try reader.require("repository"),
            path: try reader.require("path"),
            killed: try reader.int("killed")
        )
    }

    private static func decodeWorktreeNotQuiescent(_ reader: PayloadReader) throws -> JournalEvent {
        .worktreeNotQuiescent(
            featureID: try reader.int64("feature_id"),
            repository: try reader.require("repository"),
            path: try reader.require("path"),
            remaining: try reader.int("remaining")
        )
    }

    private static func decodeWorktreeWIPCommitted(_ reader: PayloadReader) throws -> JournalEvent {
        .worktreeWIPCommitted(
            featureID: try reader.int64("feature_id"),
            repository: try reader.require("repository"),
            wipCommit: try reader.require("wip_commit"),
            wipRef: try reader.require("wip_ref"),
            resetTo: reader.payload?["reset_to"]
        )
    }

    private static func decodeWorktreeReconciliationFailed(_ reader: PayloadReader) throws -> JournalEvent {
        .worktreeReconciliationFailed(
            featureID: try reader.int64("feature_id"),
            repository: try reader.require("repository"),
            path: try reader.require("path"),
            reason: try reader.require("reason")
        )
    }
}

// MARK: - PayloadReader

private struct PayloadReader: Sendable {
    let payload: [String: String]?
    let rowID: Int64

    func require(_ key: String) throws -> String {
        guard let payload, let value = payload[key] else {
            throw JournalError.eventUnreadable(id: rowID)
        }
        return value
    }

    func date(_ key: String) throws -> Date {
        let text = try require(key)
        return try JournalStore.date(text) {
            JournalError.eventUnreadable(id: rowID)
        }
    }

    func runID(_ key: String) throws -> RunID {
        let text = try require(key)
        guard let runID = RunID(rawValue: text) else {
            throw JournalError.eventUnreadable(id: rowID)
        }
        return runID
    }

    func act(_ key: String) throws -> Act {
        let text = try require(key)
        guard let act = Act(rawValue: text) else {
            throw JournalError.eventUnreadable(id: rowID)
        }
        return act
    }

    func mode(_ key: String) throws -> NightMode {
        let text = try require(key)
        guard let mode = NightMode(rawValue: text) else {
            throw JournalError.eventUnreadable(id: rowID)
        }
        return mode
    }

    func int64(_ key: String) throws -> Int64 {
        let text = try require(key)
        guard let value = Int64(text) else {
            throw JournalError.eventUnreadable(id: rowID)
        }
        return value
    }

    func closeReason(_ key: String) throws -> NightCloseReason {
        let text = try require(key)
        guard let reason = NightCloseReason(rawValue: text) else {
            throw JournalError.eventUnreadable(id: rowID)
        }
        return reason
    }

    func nightStart(_ key: String) throws -> NightStart {
        let text = try require(key)
        guard let nightStart = NightStart(rawValue: text) else {
            throw JournalError.eventUnreadable(id: rowID)
        }
        return nightStart
    }

    func uuid(_ key: String) throws -> UUID {
        let text = try require(key)
        guard let uuid = UUID(uuidString: text) else {
            throw JournalError.eventUnreadable(id: rowID)
        }
        return uuid
    }

    func cardState(_ key: String) throws -> CardState {
        let text = try require(key)
        guard let state = CardState(rawValue: text) else {
            throw JournalError.eventUnreadable(id: rowID)
        }
        return state
    }

    func int(_ key: String) throws -> Int {
        let text = try require(key)
        guard let value = Int(text) else {
            throw JournalError.eventUnreadable(id: rowID)
        }
        return value
    }

    func optionalDate(_ key: String) throws -> Date? {
        guard let payload, let text = payload[key] else {
            return nil
        }
        return try JournalStore.date(text) {
            JournalError.eventUnreadable(id: rowID)
        }
    }
}
