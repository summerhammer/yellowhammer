import Domain
import Foundation
import Journal

/// The comment posted on a Feature Issue closed by merge (roadmap P10.8; spec: landing/announce-a-
/// partial-landing). Pure: built from what the closure computed, with no Journal or board access. A
/// record, not an acknowledgement — it states no aggregate pass/fail verdict, and it is explicit that
/// the Feature is not Done.
public struct FeatureMergeClosureComment: Equatable, Sendable {
    /// A Blocked Card carried forward, awaiting Adoption (roadmap P10.7's detachment, reused here).
    public struct CarriedForwardCard: Equatable, Sendable {
        public let issueID: String
        public let blockReason: BlockReason?

        public init(issueID: String, blockReason: BlockReason?) {
            self.issueID = issueID
            self.blockReason = blockReason
        }
    }

    /// Every merged repository, keyed by name, with the mainline commit first observed to contain the
    /// Feature Branch.
    public let landings: [String: String]
    public let carriedForward: [CarriedForwardCard]
    /// The issue ids of the Cycle's Done Cards, recorded as accepted.
    public let acceptedCards: [String]
    /// The recorded Verification's unmet or unresolved clauses, if the Feature was ever verified before
    /// the merge closed it. Usually empty: a merge closure is unverified.
    public let unmetClauses: [ClauseVerificationRecord]
    /// The Night whose morning the merge concluded, per the triaged-Night rule.
    public let triagedNightStart: NightStart
    /// The Night the merge was actually observed on.
    public let observingNightStart: NightStart

    public init(
        landings: [String: String], carriedForward: [CarriedForwardCard], acceptedCards: [String],
        unmetClauses: [ClauseVerificationRecord], triagedNightStart: NightStart, observingNightStart: NightStart
    ) {
        self.landings = landings
        self.carriedForward = carriedForward
        self.acceptedCards = acceptedCards
        self.unmetClauses = unmetClauses
        self.triagedNightStart = triagedNightStart
        self.observingNightStart = observingNightStart
    }

    /// The comment body: the closed-by-merge headline, the merged repositories, any still-unmet clauses
    /// (omitted when there are none), what carried forward, what was accepted, and the observation's own
    /// limitation.
    public func body() -> String {
        var lines = [
            """
            **Closed by merge.** All \(landings.count) of this Feature's Feature Branches are ancestors \
            of mainline, so the Operator's merge closed this Feature unverified and archived its Cycle. \
            It is not Done.
            """
        ]

        lines.append("")
        lines.append("## Merged")
        for repository in landings.keys.sorted() {
            lines.append("- \(repository): mainline \(landings[repository]!) contains the Feature Branch")
        }

        if !unmetClauses.isEmpty {
            lines.append("")
            lines.append("## Still unmet")
            lines += unmetClauses.map { "- " + VerificationReport.line(for: $0) }
        }

        lines.append("")
        lines.append("## Carried forward")
        if carriedForward.isEmpty {
            lines.append("- none")
        } else {
            for card in carriedForward.sorted(by: { $0.issueID < $1.issueID }) {
                let reason = card.blockReason?.rawValue ?? "no Block Reason recorded"
                lines.append(
                    "- \(card.issueID) — Blocked (\(reason)), awaiting Adoption by a later Feature; its counters "
                        + "and round history are intact."
                )
            }
        }

        lines.append("")
        lines.append("## Accepted")
        if acceptedCards.isEmpty {
            lines.append("No green Cards to accept.")
        } else {
            let named = acceptedCards.sorted().joined(separator: ", ")
            lines.append("\(acceptedCards.count) green Cards recorded as accepted: \(named)")
        }
        lines.append("Night \(triagedNightStart) is recorded as triaged.")

        lines.append("")
        lines.append(
            "Observed on Night \(observingNightStart) from mainline ancestry; Yellowhammer never reads GitHub, "
                + "so this can lag the merge."
        )

        return lines.joined(separator: "\n")
    }
}
