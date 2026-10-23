import Domain
import Foundation

/// The comment posted on a Feature Issue whose Card reached native Done (roadmap P22.2; spec:
/// morning-report/triage-the-morning). Pure: built from what the completion computed, with no Journal or
/// board access. States the Board disposition and what was carried forward — never that any check,
/// Verification or merge succeeded.
public struct FeatureCompletionComment: Equatable, Sendable {
    /// The sentence the Feature comment (and each carried-forward Card's content) leads with.
    public static let headline = "Feature completed on Board; unfinished work carried forward"

    public let carriedForward: [FeatureReleaseComment.CarriedForwardCard]
    /// The issue ids of the Cycle's Done Cards.
    public let acceptedCards: [String]
    /// Repositories whose Worktree was kept because it held unpushed work.
    public let keptWorktrees: [String]

    public init(
        carriedForward: [FeatureReleaseComment.CarriedForwardCard], acceptedCards: [String], keptWorktrees: [String]
    ) {
        self.carriedForward = carriedForward
        self.acceptedCards = acceptedCards
        self.keptWorktrees = keptWorktrees
    }

    public func body() -> String {
        var lines = [
            "**\(Self.headline).** This Feature's Cycle is closed on the Board's word alone: it frees this "
                + "Project's in-flight slot. That records no check, no Verification and no merge."
        ]

        lines.append("")
        lines.append("## Carried forward")
        if carriedForward.isEmpty {
            lines.append("- none")
        } else {
            for card in carriedForward.sorted(by: { $0.issueID < $1.issueID }) {
                let reason = card.blockReason?.rawValue ?? "no Block Reason recorded"
                var line = "- \(card.issueID) — Blocked (\(reason)); a later Feature may adopt it with its " +
                    "history intact."
                if let waitsOn = card.waitsOn {
                    line += " It is held behind \(waitsOn.issueID) (\"\(waitsOn.title)\")."
                }
                lines.append(line)
            }
        }

        if !acceptedCards.isEmpty {
            lines.append("")
            lines.append("## Done Cards")
            lines.append(acceptedCards.sorted().joined(separator: ", "))
        }

        if !keptWorktrees.isEmpty {
            lines.append("")
            lines.append("## Worktrees kept")
            for repository in keptWorktrees.sorted() {
                lines.append("- \(repository): holds unpushed work, so its Worktree was kept rather than discarded.")
            }
        }

        return lines.joined(separator: "\n")
    }
}
