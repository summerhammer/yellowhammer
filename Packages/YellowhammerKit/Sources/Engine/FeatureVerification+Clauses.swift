import Domain
import Foundation
import Journal

// The clauses Verification judges, and the outcomes the engine decides itself (roadmap P10.5).

/// One clause to judge, with the state of the Card it belongs to (nil for a Feature-level clause).
struct VerificationCandidate: Sendable {
    let clause: ClauseRecord
    let cardState: CardState?

    /// Clause ids are unique only within their issue.
    var key: String { "\(clause.issueID)\u{1F}\(clause.cid)" }

    func record(
        verdict: ClauseVerdict, whatWasChecked: String, interpretation: String, judgedBy: ClauseJudge
    ) -> ClauseVerificationRecord {
        ClauseVerificationRecord(
            issueID: clause.issueID, cid: clause.cid, level: clause.level, text: clause.text,
            locationID: clause.locationID, citationProvenance: clause.citationProvenance, verdict: verdict,
            whatWasChecked: whatWasChecked, interpretation: interpretation, judgedBy: judgedBy,
            invalidatedCause: clause.invalidated ? (clause.invalidatedCause ?? "unspecified") : nil
        )
    }
}

extension FeatureVerification {
    /// The Feature-level clauses, then each non-Shelved Card's in authored order (Card creation order),
    /// straight from the Journal's `clause` table. A Shelved Card's clauses are not judged at all, nor are those of a removed Card
    /// (trashed, or archived while in play; OQ142).
    func gatherClauses(_ context: LandActFeatureContext) throws -> [VerificationCandidate] {
        let journal = context.act.journal
        var candidates = try journal.clauses(issueID: context.feature.issueID)
            .map { VerificationCandidate(clause: $0, cardState: nil) }
        let cards = try journal.cards(cycleID: context.cycleID).sorted { $0.id < $1.id }
        for card in cards where card.state != .shelved && !card.isRemovedFromBoard {
            candidates += try journal.clauses(issueID: card.issueID)
                .map { VerificationCandidate(clause: $0, cardState: card.state) }
        }
        return candidates
    }

    /// The outcomes the engine decides without an agent, by clause key. A clause of a Card that did not
    /// complete is `unmet`; of those left, one whose Spec Citation does not resolve is `unresolved`.
    func decideByEngine(
        _ candidates: [VerificationCandidate], context: LandActFeatureContext
    ) async throws -> [String: ClauseVerificationRecord] {
        var judged: [String: ClauseVerificationRecord] = [:]
        for candidate in candidates {
            if let state = candidate.cardState, state != .done {
                judged[candidate.key] = candidate.record(
                    verdict: .unmet,
                    whatWasChecked: "the Card did not complete (state: \(state.rawValue))",
                    interpretation: "not verified: the work this clause covers did not land",
                    judgedBy: .engine
                )
            }
        }
        let remaining = candidates.filter { judged[$0.key] == nil }
        guard !remaining.isEmpty else { return judged }
        guard let repositories = context.act.repositories else {
            throw VerificationFault(
                reason: "this Project's repositories are not configured, so Spec Citations cannot be resolved"
            )
        }
        for candidate in remaining {
            let resolution = await citations.resolve(
                SpecCitation(candidate.clause.locationID), in: repositories, mainlines: context.act.mainlines
            )
            guard !resolution.resolves else { continue }
            let reason = resolution.failureReason ?? "the citation could not be resolved"
            judged[candidate.key] = candidate.record(
                verdict: .unresolved,
                whatWasChecked: "the Spec Citation no longer resolves (\(reason)); this is a citation for the "
                    + "Specification Author to repair, not unfinished work",
                interpretation: "not verified: the citation could not be read",
                judgedBy: .engine
            )
        }
        return judged
    }
}
