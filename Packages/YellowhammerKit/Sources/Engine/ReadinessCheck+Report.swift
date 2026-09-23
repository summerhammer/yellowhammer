import Domain
import Foundation
import Journal
import Repositories

// Recording a Divergence or a readiness failure onto the Card, through the Outbox (P8.2).
extension ReadinessCheck {
    func recordDivergence(
        report: CardProvenanceReport, card: CardRecord, context: BuildActContext
    ) async throws -> ReadinessVerdict {
        let journal = context.act.journal
        let staleResults = report.results.filter(\.isDiverged)
        let first = staleResults[0]
        let count = try journal.incrementConsecutiveDivergences(cardID: card.id)

        let record = try await transitionToWaitingOnYou(reason: .divergence, card: card, context: context)

        let allChangedPaths = Array(Set(staleResults.flatMap(\.changedPaths))).sorted()
        try journal.append(
            .cardDiverged(
                cardID: card.id, issueID: card.issueID, repository: first.repository, changedPaths: allChangedPaths
            ),
            act: context.act.act, runID: context.act.runID, nightID: context.act.night.id
        )

        if let outbox = context.act.outbox {
            let body = divergenceCommentBody(staleResults: staleResults, consecutiveDivergences: count)
            let key = "divergence:\(card.issueID):\(record.stateVersion)"
            let write = BoardWrite.createComment(issue: BoardObjectID(rawValue: card.issueID), body: body)
            _ = try await outbox.post(OutboxWrite(key: key, write: write, cardID: card.id))
        }

        return .diverged(DivergenceFinding(
            repository: first.repository, changedPaths: allChangedPaths, consecutiveDivergences: count
        ))
    }

    /// Transitions the Card to Waiting on You under the given reason, through the board projection when
    /// the Outbox and board are wired, and directly on the Journal otherwise. The assignee is whatever
    /// the Operator identity resolves to right now — nil when unconfigured or no longer an active
    /// workspace member — and the state is written either way.
    private func transitionToWaitingOnYou(
        reason: WaitingReason, card: CardRecord, context: BuildActContext
    ) async throws -> CardRecord {
        let journal = context.act.journal
        if let outbox = context.act.outbox, let board = context.act.board {
            let scope = try await BoardStateScope.resolve(using: board.provisioning)
            let projection = BoardStateProjection(journal: journal, outbox: outbox, scope: scope)
            let assignee = await operatorIdentity.assignee(on: board.reading)
            switch try await projection.transition(card: card, to: .waitingOnYou(reason, operator: assignee)) {
            case .unchanged(let record), .posted(let record, _), .deferred(let record, _), .failed(let record, _):
                return record
            }
        }
        return try journal.transitionCard(
            cardID: card.id, to: .waitingOnYou, waitingReason: reason,
            runID: context.act.runID, act: context.act.act, nightID: context.act.night.id
        )
    }

    /// A Card scoped onto a protected path is refused before dispatch: moved to Waiting on You,
    /// carrying the protected path as its reason, with no Attempt recorded (P8.3).
    func recordRefusal(
        match: ProtectedPathRefusal, card: CardRecord, context: BuildActContext
    ) async throws -> ReadinessVerdict {
        let journal = context.act.journal
        let record = try await transitionToWaitingOnYou(reason: .question, card: card, context: context)

        try journal.append(
            .protectedPathRefused(
                cardID: card.id, issueID: card.issueID, repository: match.repository,
                declaredPath: match.declaredPath, protectedPath: match.protectedPath
            ),
            act: context.act.act, runID: context.act.runID, nightID: context.act.night.id
        )

        if let outbox = context.act.outbox {
            let body = refusalCommentBody(match: match)
            let key = "protected-path:\(card.issueID):\(record.stateVersion)"
            let write = BoardWrite.createComment(issue: BoardObjectID(rawValue: card.issueID), body: body)
            _ = try await outbox.post(OutboxWrite(key: key, write: write, cardID: card.id))
        }

        return .refused(match)
    }

    private func refusalCommentBody(match: ProtectedPathRefusal) -> String {
        [
            "This Card was not dispatched and consumed no Attempt: its declared scope " +
                "`\(match.declaredPath)` falls under the protected path `\(match.protectedPath)` of " +
                "repository `\(match.repository)`. It was moved to Waiting on You — change the Card's " +
                "scope or the repository's `protected_paths` to run it.",
            ProtectedPaths.limitation
        ].joined(separator: "\n")
    }

    private func divergenceCommentBody(staleResults: [RepoProvenanceResult], consecutiveDivergences: Int) -> String {
        var lines = [
            "This Card has diverged: at least one Transcription Block's recorded contract has moved on " +
                "its repository's mainline. It was moved to Waiting on You."
        ]
        for result in staleResults {
            let paths = result.changedPaths.joined(separator: ", ")
            lines.append("- \(result.repository): \(paths)")
        }
        lines.append("Consecutive Divergences: \(consecutiveDivergences).")
        return lines.joined(separator: "\n")
    }

    func recordFailure(failures: [ReadinessFailure], card: CardRecord, context: BuildActContext) async throws {
        let journal = context.act.journal
        let descriptions = failures.map(\.description)
        try journal.append(
            .readinessCheckFailed(cardID: card.id, issueID: card.issueID, failures: descriptions),
            act: context.act.act, runID: context.act.runID, nightID: context.act.night.id
        )

        guard let outbox = context.act.outbox else { return }
        let body = (
            ["This Card was not dispatched and consumed no Attempt because it is not Ready:"]
                + descriptions.map { "- \($0)" }
        ).joined(separator: "\n")
        let key = "readiness:\(card.issueID):\(ManagedBlockFence.sha256(descriptions.joined(separator: "\n")))"
        _ = try await outbox.post(OutboxWrite(
            key: key, write: .createComment(issue: BoardObjectID(rawValue: card.issueID), body: body), cardID: card.id
        ))
    }
}
