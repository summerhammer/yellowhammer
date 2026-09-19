import Domain
import Foundation

// MARK: - PayloadReader

struct PayloadReader: Sendable {
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

    func bool(_ key: String) throws -> Bool {
        switch try require(key) {
        case "true": return true
        case "false": return false
        default: throw JournalError.eventUnreadable(id: rowID)
        }
    }

    func pass(_ key: String) throws -> RunPass {
        let text = try require(key)
        guard let pass = RunPass(rawValue: text) else {
            throw JournalError.eventUnreadable(id: rowID)
        }
        return pass
    }

    func route() throws -> Route {
        guard let route = Route(
            cli: try require("route_cli"), model: try require("route_model"), effort: try require("route_effort")
        ) else {
            throw JournalError.eventUnreadable(id: rowID)
        }
        return route
    }
}
