import Domain
import Foundation

// The decode helper for agentPassNotShownInOrca (graph-execution/see-and-open-agent-sessions-in-orca,
// AC orca-unreachable), split out of JournalEvent+Decoding.swift to keep that file under the file length limit.

extension JournalEvent {
    static func decodeAgentPassNotShownInOrca(_ reader: PayloadReader) throws -> JournalEvent {
        .agentPassNotShownInOrca(
            cardID: try reader.int64("card_id"),
            issueID: try reader.require("issue_id"),
            attemptID: try reader.int64("attempt_id"),
            pass: try reader.pass("pass"),
            cli: try reader.require("cli"),
            reason: try reader.require("reason")
        )
    }
}
