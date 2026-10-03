import Domain
import Foundation

// The App Installation token-pair refresh event's payload and decoding, and the rate-budget event's
// (both name the App Installation), split out of
// JournalEvent+Payload.swift and JournalEvent+Decoding.swift to keep those under the file length limit.
// The payload never carries a token: the record's strings were scrubbed before they reached the Engine.

extension JournalEvent {
    static func rateBudgetPayload(degradation: String, installation: AppInstallationLabel?) -> [String: String] {
        var payload = ["budget": "installation-wide", "degradation": degradation]
        if let installation {
            payload["installation"] = installation.name
            payload["workspace"] = installation.workspace.rawValue
        }
        return payload
    }

    static func decodeRateBudgetExhausted(_ reader: PayloadReader) throws -> JournalEvent {
        var installation: AppInstallationLabel?
        if let name = reader.payload?["installation"], let workspace = reader.payload?["workspace"] {
            installation = AppInstallationLabel(name: name, workspace: BoardObjectID(rawValue: workspace))
        }
        return .rateBudgetExhausted(degradation: try reader.require("degradation"), installation: installation)
    }

    static func payload(of refresh: AppInstallationTokenRefresh) -> [String: String] {
        var payload = [
            "installation": refresh.installation.name,
            "workspace": refresh.installation.workspace.rawValue,
            "attempted_at": JournalStore.timestamp(refresh.attemptedAt),
            "trigger": refresh.trigger.rawValue,
            "previous_expires_at": JournalStore.timestamp(refresh.previousExpiresAt)
        ]
        switch refresh.outcome {
        case .refreshed(let expiresAt):
            payload["outcome"] = "refreshed"
            payload["expires_at"] = JournalStore.timestamp(expiresAt)
        case .refused(let refusal):
            payload["outcome"] = "refused"
            payload["message"] = refusal.message
            payload["status"] = String(refusal.status)
            if let code = refusal.code { payload["code"] = code }
            if let description = refusal.description { payload["description"] = description }
        case .unreachable(let message):
            payload["outcome"] = "unreachable"
            payload["message"] = message
        case .notStored(let message):
            payload["outcome"] = "not-stored"
            payload["message"] = message
        }
        return payload
    }

    static func decodeAppInstallationTokenRefresh(_ reader: PayloadReader) throws -> JournalEvent {
        guard let trigger = AppInstallationTokenRefresh.Trigger(rawValue: try reader.require("trigger")) else {
            throw JournalError.eventUnreadable(id: reader.rowID)
        }
        let outcome: AppInstallationTokenRefresh.Outcome
        switch try reader.require("outcome") {
        case "refreshed":
            outcome = .refreshed(expiresAt: try reader.date("expires_at"))
        case "refused":
            guard let status = Int(try reader.require("status")) else {
                throw JournalError.eventUnreadable(id: reader.rowID)
            }
            outcome = .refused(.init(
                status: status, code: reader.payload?["code"], description: reader.payload?["description"],
                message: try reader.require("message")
            ))
        case "unreachable":
            outcome = .unreachable(message: try reader.require("message"))
        case "not-stored":
            outcome = .notStored(message: try reader.require("message"))
        default:
            throw JournalError.eventUnreadable(id: reader.rowID)
        }
        // `installation` and `workspace` are required, not optional: a Journal written before these keys is
        // refused and recreated at `journal-schema-2` (roadmap L1.3), and pre-1.0 the Journal is never
        // migrated incrementally, so no readable row lacks them.
        let installation = AppInstallationLabel(
            name: try reader.require("installation"),
            workspace: BoardObjectID(rawValue: try reader.require("workspace"))
        )
        return .appInstallationTokenRefresh(AppInstallationTokenRefresh(
            installation: installation, attemptedAt: try reader.date("attempted_at"), trigger: trigger,
            previousExpiresAt: try reader.date("previous_expires_at"), outcome: outcome
        ))
    }
}
