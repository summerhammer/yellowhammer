import Domain
import Foundation
import Journal

extension CardRun {
    /// Records a reviewer's changes-requested as a Round of the open Attempt (never an Attempt: nothing
    /// ends and no Route changes), attaches the requested changes to the Card, and reads the Rounds back
    /// to say whether the worker may go again. Shares its round budget with the Check's Rounds
    /// (`CardRun+CheckRound.swift`): both Lenses spend the same budget.
    func recordReviewRound(
        frame: CardRunFrame, attemptID: Int64, judgedCommit: String, requestedChanges: String
    ) async throws -> (rounds: [RoundRecord], budget: RoundBudget) {
        let round = RoundToRecord(
            attemptID: attemptID, lens: .review, verdict: "changes requested", requestedChanges: requestedChanges,
            judgedCommit: judgedCommit, commentKeyPrefix: "review-round"
        )
        return try await recordRound(round, frame: frame) { number in
            Self.reviewRoundComment(round: number, judgedCommit: judgedCommit, requestedChanges: requestedChanges)
        }
    }

    /// The Card comment for a reviewer's changes-requested: which Round, the commit it judged, and the
    /// requested changes in full (the Managed Block's own account of the Round caps what it shows).
    static func reviewRoundComment(round: Int, judgedCommit: String, requestedChanges: String) -> String {
        var fence = "```"
        while requestedChanges.contains(fence) { fence += "`" }
        return [
            "The reviewer requested changes in Round \(round), judging commit `\(judgedCommit)`.",
            "\(fence)\n\(requestedChanges)\n\(fence)"
        ].joined(separator: "\n\n")
    }
}
