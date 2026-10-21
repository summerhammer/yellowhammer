import Domain
import Foundation

// MARK: - Partial Landing

extension PullRequestBody {
    static func renderPartial(_ input: PullRequestBodyInput) -> String {
        let incomplete = input.incompleteCards
        let waitingCount = incomplete.filter { $0.state == .waitingOnYou }.count
        let blockedCount = incomplete.filter { $0.state == .blocked }.count
        let landedCount = input.cycleCards.filter { $0.state == .done }.count
        let totalCardCount = input.cycleCards.count
        let uCount = input.effectiveUnmetClauses.count
        let xCount = input.verificationReport?.notChecked.count ?? 0
        // The "carried forward" *list* (below) names only a Card still Waiting on You at landing, per
        // the story's own wording — that is the one auto-Blocked and sent to Adoption. Line 2's fixed
        // copy ("<c_count> unfinished Cards are carried forward and auto-Blocked awaiting Adoption")
        // reads as one sentence over the whole unfinished set, though: every Blocked-or-Waiting-on-You
        // Card is "carried forward" out of this landing, and only the Waiting-on-You subset of it also
        // needs auto-Blocking. So c_count here counts every incomplete Card (Blocked or Waiting on
        // You), not just the Waiting-on-You ones the list section names.
        let carried = incomplete.filter { $0.state == .waitingOnYou }

        var lines: [String] = []
        lines.append(openingLine1(
            waitingCount: waitingCount, blockedCount: blockedCount, landedCount: landedCount,
            totalCardCount: totalCardCount, input: input
        ))
        lines.append(openingLine2(
            landedCount: landedCount, totalCardCount: totalCardCount, uCount: uCount, xCount: xCount,
            carriedCount: incomplete.count, input: input
        ))
        lines.append(stampLine(input))
        // Agent ruling 2026-10-21 item 12: Lines 1-2 and the stamp stay word for word on a stacked pull
        // request; the stack notice follows the stamp directly (sponsor ruling 2026-10-21, Q3).
        if let notice = input.stackNotice {
            lines.append(notice.rendered)
        }
        lines.append("")
        lines.append(incompleteCardsSection(incomplete))
        lines.append("")
        lines.append(unmetClausesSection(input.effectiveUnmetClauses))
        lines.append("")
        lines.append(carriedForwardSection(carried))
        lines.append("")
        lines.append(
            "Merging all \(input.pushedRepositoryCount) pull requests closes the Feature unverified and "
                + "archives its Cycle; merging fewer than \(input.pushedRepositoryCount) closes nothing "
                + "and releases nothing."
        )
        lines.append(
            "Merging satisfies the landing gate for the repositories it reached and releases the next Feature."
        )
        lines.append(MergeCommitRecommendation.pullRequestBody)
        lines.append("")
        lines.append(cardListSection(title: "Cards in this repository", cards: input.laneCards))
        lines.append("")
        if let report = input.verificationReport {
            lines.append(report.markdownSection())
            lines.append("")
        }
        lines.append(mainlineVerdictLine(input))
        lines.append("")
        lines.append(featurePointerLine(input))
        return lines.joined(separator: "\n")
    }

    /// Line 1 (OQ31, fixed copy): worst-first — `waiting on you` dominates `blocked`, mirroring the
    /// Roll-up lattice's own worst-first rule (`waiting` before `blocked`).
    static func openingLine1(
        waitingCount: Int, blockedCount: Int, landedCount: Int, totalCardCount: Int, input: PullRequestBodyInput
    ) -> String {
        let dispositionWord = waitingCount > 0
            ? "\(waitingCount) waiting on you"
            : "\(blockedCount) blocked"
        let notes = input.noPullRequestRepositories.isEmpty
            ? "" : " " + FeatureRollUp.noPullRequestNotes(input.noPullRequestRepositories)
        return "**partial · \(landedCount) of \(totalCardCount) Cards landed · "
            + "0 of \(input.pushedRepositoryCount) merged · \(dispositionWord)**" + notes
    }

    static func openingLine2(
        landedCount: Int, totalCardCount: Int, uCount: Int, xCount: Int = 0, carriedCount: Int,
        input: PullRequestBodyInput
    ) -> String {
        let notCheckedFragment = xCount > 0 ? ", \(xCount) Definition of Done clauses were not checked" : ""
        return "This pull request is 1 of \(input.pushedRepositoryCount) for Feature '\(input.featureTitle)'. "
            + "Merging all \(input.pushedRepositoryCount) pull requests closes the Feature unverified and "
            + "archives its Cycle; merging fewer than \(input.pushedRepositoryCount) closes nothing and "
            + "releases nothing. \(landedCount) of \(totalCardCount) Cards landed; "
            + "\(uCount) Definition of Done clauses remain "
            + "unmet\(notCheckedFragment); \(carriedCount) unfinished Cards are carried forward "
            + "and auto-Blocked awaiting Adoption."
    }

    static func stampLine(_ input: PullRequestBodyInput) -> String {
        let link = input.featureIssueURL.map { "[Feature Card](\($0))" } ?? "Feature Card"
        return "*As of Night \(input.nightID) (\(input.nightTimestamp)). Live state: \(link)*"
    }

    static func incompleteCardsSection(_ cards: [PullRequestBodyCard]) -> String {
        guard !cards.isEmpty else { return "Incomplete Cards: none." }
        var lines = ["Incomplete Cards (every repository):"]
        for card in cards {
            let disposition = card.state == .waitingOnYou ? "Waiting on You" : "Blocked"
            let reason = card.state == .waitingOnYou
                ? (card.waitingReason?.rawValue ?? "unspecified")
                : (card.blockReason ?? "unspecified")
            let hole = card.isLaneHole ? " (lane hole)" : ""
            lines.append("- \(card.title) [\(card.repository)]: \(disposition) — \(reason)\(hole)")
        }
        return lines.joined(separator: "\n")
    }

    static func unmetClausesSection(_ clauses: [PullRequestBodyUnmetClause]) -> String {
        // Without a Verification report (a land Act with no Verification seam wired), `clauses` is the
        // set known at landing time from the incomplete Cards, and this section claims nothing more. With
        // one, it is derived from the report's own unmet and unresolved clauses, so the two agree.
        guard !clauses.isEmpty else { return "Definition of Done clauses unmet: none." }
        var lines = ["Definition of Done clauses unmet:"]
        for clause in clauses {
            lines.append("- \(clause.workCardTitle): \"\(clause.text)\" (\(clause.citation)) — unmet")
        }
        return lines.joined(separator: "\n")
    }

    static func carriedForwardSection(_ cards: [PullRequestBodyCard]) -> String {
        guard !cards.isEmpty else { return "Carried forward: none." }
        var lines = ["Carried forward (Waiting on You, auto-Blocked awaiting Adoption):"]
        for card in cards {
            lines.append("- \(card.title) [\(card.repository)]")
        }
        return lines.joined(separator: "\n")
    }
}
