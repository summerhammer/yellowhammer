import Domain
import Foundation

/// The comment posted on a Feature Issue the settle gesture released (roadmap P10.9; spec:
/// morning-report/triage-the-morning). Pure: built from what the release computed, with no Journal or
/// board access. States plainly that the release lands nothing — never that any abandoned work landed.
public struct FeatureReleaseComment: Equatable, Sendable {
    /// A Card carried forward, auto-Blocked and awaiting Adoption.
    public struct CarriedForwardCard: Equatable, Sendable {
        public let issueID: String
        public let blockReason: BlockReason?

        public init(issueID: String, blockReason: BlockReason?) {
            self.issueID = issueID
            self.blockReason = blockReason
        }
    }

    public let carriedForward: [CarriedForwardCard]
    /// The issue ids of the Cycle's Done Cards, recorded as accepted.
    public let acceptedCards: [String]
    /// Repositories with a recorded pull request but no recorded landing: left open on GitHub, never
    /// closed by this release.
    public let abandonedRepositories: [String]
    public let triagedNightStart: NightStart

    public init(
        carriedForward: [CarriedForwardCard], acceptedCards: [String], abandonedRepositories: [String],
        triagedNightStart: NightStart
    ) {
        self.carriedForward = carriedForward
        self.acceptedCards = acceptedCards
        self.abandonedRepositories = abandonedRepositories
        self.triagedNightStart = triagedNightStart
    }

    public func body() -> String {
        var lines = [
            """
            **Released.** This Feature is stop-with-salvage: it frees this Project's in-flight slot and \
            drops out of the predecessor-ancestry walk, so the next Night authors against mainline as it \
            stands, without this Feature's work. It lands nothing, satisfies the predecessor-ancestry \
            gate for no repository, and is never counted in the merged fraction. This Feature Issue is \
            not archived and stays re-enterable.
            """
        ]

        lines.append("")
        lines.append("## Carried forward")
        if carriedForward.isEmpty {
            lines.append("- none")
        } else {
            for card in carriedForward.sorted(by: { $0.issueID < $1.issueID }) {
                let reason = card.blockReason?.rawValue ?? "no Block Reason recorded"
                lines.append(
                    "- \(card.issueID) — Blocked (\(reason)), awaiting Adoption by a later Feature; its "
                        + "counters and round history are intact."
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

        lines.append("")
        lines.append("## Abandoned pull requests")
        if abandonedRepositories.isEmpty {
            lines.append("- none")
        } else {
            for repository in abandonedRepositories.sorted() {
                lines.append(
                    "- \(repository): left open on GitHub, never closed by this release. Merging it "
                        + "afterwards is untracked — this release does not know it happened."
                )
            }
        }

        lines.append("")
        lines.append("Night \(triagedNightStart) is recorded as triaged.")

        return lines.joined(separator: "\n")
    }
}
