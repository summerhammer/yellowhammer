import Domain
import Foundation

// The rehearsal boundary events' decode helpers (system-overview, Environment Differences, P8.11),
// split out of JournalEvent+Decoding.swift (whose exhaustive switch still dispatches to them) to keep
// that file under the file length limit.

extension JournalEvent {
    static func decodeAgentCLIProcessSpawned(_ reader: PayloadReader) throws -> JournalEvent {
        .agentCLIProcessSpawned(
            cardID: try reader.int64("card_id"),
            issueID: try reader.require("issue_id"),
            attemptID: try reader.int64("attempt_id"),
            pass: try reader.pass("pass"),
            cli: try reader.require("cli")
        )
    }

    static func decodeRehearsalFixtureAnswered(_ reader: PayloadReader) throws -> JournalEvent {
        .rehearsalFixtureAnswered(
            cardID: try reader.int64("card_id"),
            issueID: try reader.require("issue_id"),
            attemptID: try reader.int64("attempt_id"),
            pass: try reader.pass("pass"),
            fixture: try reader.require("fixture")
        )
    }
}
