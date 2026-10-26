import Domain
import Foundation
import Journal

// The records a pass writes around its dispatch: its payloads, Round, provenance, capture request and
// usage-limit backoff. Split from ``CardRun+Passes.swift`` to keep that file within its length limit.

extension CardRun {
    /// A new Attempt's preserved work (OQ60) and an answered question (P11.2) are both context the frame
    /// carries for the whole run: merged onto every pass instruction unless the caller already carries
    /// its own value for either, so neither ever clobbers `wip` or `roundFeedback`.
    static func effectivePayloads(_ payloads: InstructionPayloads, frame: CardRunFrame) -> InstructionPayloads {
        InstructionPayloads(
            wip: payloads.wip ?? frame.wipContext,
            answeredQuestion: payloads.answeredQuestion ?? frame.answeredQuestion,
            bankedReplies: payloads.bankedReplies.isEmpty ? frame.bankedReplies : payloads.bankedReplies,
            roundFeedback: payloads.roundFeedback
        )
    }

    /// The Round this pass belongs to: one past the Rounds that asked for changes.
    func currentRound(of attemptID: Int64, frame: CardRunFrame) throws -> Int {
        guard let attemptRecord = try frame.journal.attempt(id: attemptID) else { return 1 }
        return 1 + attemptRecord.rounds.count { $0.requestedChanges != nil }
    }

    static func provenance(
        recordID: String, pass: RunPass, frame: CardRunFrame, attemptID: Int64, round: Int
    ) -> DispatchProvenance {
        DispatchProvenance(
            recordID: recordID,
            family: PromptFamily(pass: pass) ?? .worker,
            projectID: frame.journal.projectID.rawValue,
            runID: frame.context.act.runID.rawValue,
            nightID: frame.context.act.night.id,
            featureIssueID: frame.context.feature.issueID,
            workCardIssueID: frame.card.issueID,
            cardID: frame.card.id,
            attemptID: attemptID,
            round: round
        )
    }

    /// Journals the prompt capture request before the dispatch, so the Night's account can name the record
    /// even if the dispatch never returns. A dispatch that records no prompt (rehearsal) gets no request, or the
    /// Journal would name a record that can never exist.
    func requestPromptCapture(
        recordID: String, pass: RunPass, frame: CardRunFrame, attemptID: Int64, round: Int
    ) throws {
        guard dispatch.recordsPrompts else { return }
        try frame.journal.append(
            .promptCaptureRequested(
                recordID: recordID, pass: pass, cardID: frame.card.id, issueID: frame.card.issueID,
                attemptID: attemptID, round: round, ordinal: nil
            ),
            act: frame.context.act.act, runID: frame.context.act.runID, nightID: frame.context.act.night.id
        )
    }

    func recordUsageLimit(route: Route, resetHint: String?, frame: CardRunFrame) throws {
        try frame.revalidateLease()
        try frame.journal.recordUsageLimit(
            route: route, resetHint: resetHint, runID: frame.context.act.runID,
            act: frame.context.act.act, nightID: frame.context.act.night.id
        )
    }
}
