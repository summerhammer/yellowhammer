import Domain
import Foundation

// The decode helper for agentSessionHadForeignTurns (graph-execution/see-and-open-agent-sessions-in-orca,
// AC touched-session), split out of JournalEvent+Decoding.swift to keep that file under the file length limit.

extension JournalEvent {
    static func decodeAgentSessionHadForeignTurns(_ reader: PayloadReader) throws -> JournalEvent {
        .agentSessionHadForeignTurns(
            cardID: try reader.int64("card_id"),
            issueID: try reader.require("issue_id"),
            attemptID: try reader.int64("attempt_id"),
            round: try reader.int("round"),
            cli: try reader.require("cli")
        )
    }
}
