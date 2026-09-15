import Domain
import Foundation

/// One entry of the Project's append-only event log, typed so that the spec's vocabulary is the code's.
public enum JournalEvent: Equatable, Sendable {
    case actStarted
    case actEnded
    /// The Act could not complete; `reason` is what it knew when it gave up.
    case actIncomplete(reason: String)
    /// Another run of the same Project held the Act-scoped lease; this Act ran nothing.
    case actStoodDown(holder: ActLease)
    case mainlineFetchFailed(repository: String, reason: String)
    /// The resumption self-audit found a Night that never opened (OQ12).
    case absentNightDetected(nightStart: String)
    case authoringNoWorkAvailable
    case managedBlockDelimiterBroken(issueID: String)
    /// Fire-and-forget: the failure is recorded, never acted on.
    case notificationDeliveryFailed(notification: String, reason: String)
    /// The board's request budget was exhausted and the Act did less work. The budget is the
    /// identity's, shared by every Project running that night, so the record names it workspace-wide
    /// and never attributes the exhaustion to this Project's own reads.
    case rateBudgetExhausted(degradation: String)
    /// An expired Act-scoped lease was taken over by a new run: the previous run crashed or slept past its TTL.
    case leaseReclaimed(previousRunID: RunID, previousAct: Act, expiredAt: Date)

    /// The type of this event.
    public var type: JournalEventType {
        switch self {
        case .actStarted:
            .actStarted
        case .actEnded:
            .actEnded
        case .actIncomplete:
            .actIncomplete
        case .actStoodDown:
            .actStoodDown
        case .mainlineFetchFailed:
            .mainlineFetchFailed
        case .absentNightDetected:
            .absentNightDetected
        case .authoringNoWorkAvailable:
            .authoringNoWorkAvailable
        case .managedBlockDelimiterBroken:
            .managedBlockDelimiterBroken
        case .notificationDeliveryFailed:
            .notificationDeliveryFailed
        case .rateBudgetExhausted:
            .rateBudgetExhausted
        case .leaseReclaimed:
            .leaseReclaimed
        }
    }

    /// Encodes this event as a payload dictionary with sorted keys (for byte-stable storage).
    var payload: [String: String]? {
        switch self {
        case .actStarted, .actEnded:
            nil
        case .actIncomplete(let reason):
            ["reason": reason]
        case .actStoodDown(let holder):
            [
                "holder_run_id": holder.runID.rawValue,
                "holder_act": holder.act.rawValue,
                "holder_claimed_at": JournalStore.timestamp(holder.claimedAt),
                "holder_expires_at": JournalStore.timestamp(holder.expiresAt),
                "holder_heartbeat_at": JournalStore.timestamp(holder.heartbeatAt),
                "holder_mode": holder.mode.rawValue
            ]
        case .mainlineFetchFailed(let repository, let reason):
            ["reason": reason, "repository": repository]
        case .absentNightDetected(let nightStart):
            ["night_start": nightStart]
        case .authoringNoWorkAvailable:
            nil
        case .managedBlockDelimiterBroken(let issueID):
            ["issue_id": issueID]
        case .notificationDeliveryFailed(let notification, let reason):
            ["notification": notification, "reason": reason]
        case .rateBudgetExhausted(let degradation):
            ["budget": "workspace-wide", "degradation": degradation]
        case .leaseReclaimed(let previousRunID, let previousAct, let expiredAt):
            [
                "expired_at": JournalStore.timestamp(expiredAt),
                "previous_act": previousAct.rawValue,
                "previous_run_id": previousRunID.rawValue
            ]
        }
    }

    /// Decodes an event from its type and payload. Throws `JournalError.eventUnreadable(id:)` with
    /// the row id if the payload is malformed for this type.
    init(type: JournalEventType, payload: [String: String]?, rowID: Int64) throws {
        let reader = PayloadReader(payload: payload, rowID: rowID)
        self = try Self.decode(type: type, reader: reader)
    }

    // One exhaustive switch over the event vocabulary: a case per type is the whole of its complexity,
    // and the compiler's exhaustiveness check is what keeps the decoder in step with the enum.
    // swiftlint:disable:next cyclomatic_complexity
    private static func decode(type: JournalEventType, reader: PayloadReader) throws -> JournalEvent {
        switch type {
        case .actStarted:
            .actStarted
        case .actEnded:
            .actEnded
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
            .absentNightDetected(nightStart: try reader.require("night_start"))
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
        }
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
}

/// The type of a JournalEvent, with raw values matching the spec's PascalCase names.
public enum JournalEventType: String, CaseIterable, Sendable {
    case actStarted = "ActStarted"
    case actEnded = "ActEnded"
    case actIncomplete = "ActIncomplete"
    case actStoodDown = "ActStoodDown"
    case mainlineFetchFailed = "MainlineFetchFailed"
    case absentNightDetected = "AbsentNightDetected"
    case authoringNoWorkAvailable = "AuthoringNoWorkAvailable"
    case managedBlockDelimiterBroken = "ManagedBlockDelimiterBroken"
    case notificationDeliveryFailed = "NotificationDeliveryFailed"
    case rateBudgetExhausted = "RateBudgetExhausted"
    case leaseReclaimed = "LeaseReclaimed"
}
