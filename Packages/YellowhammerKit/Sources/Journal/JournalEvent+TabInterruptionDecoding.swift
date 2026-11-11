import Domain

extension JournalEvent {
    static func decodeAgentTabInterruptionObserved(_ reader: PayloadReader) throws -> JournalEvent {
        let signalText = try reader.require("received_signals")
        let signals = try signalText.split(separator: ",").map { part -> Int32 in
            guard let signal = Int32(part) else { throw JournalError.eventUnreadable(id: reader.rowID) }
            return signal
        }
        guard let tabState = TabInterruptionEvidence.TabState(rawValue: try reader.require("tab_state")),
              let loginState = TabInterruptionEvidence.LoginState(rawValue: try reader.require("login_state")) else {
            throw JournalError.eventUnreadable(id: reader.rowID)
        }
        return .agentTabInterruptionObserved(
            cardID: try reader.int64("card_id"), issueID: try reader.require("issue_id"),
            attemptID: try reader.int64("attempt_id"), pass: try reader.pass("pass"),
            engineSignalled: try reader.bool("engine_signalled"), tabState: tabState.rawValue,
            loginState: loginState.rawValue, receivedSignals: signals
        )
    }
}
