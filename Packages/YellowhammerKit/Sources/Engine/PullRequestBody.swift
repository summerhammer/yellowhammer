import Domain
import Foundation
import Journal

/// One Card's rendering input for a pull request body (roadmap P10.4). Pure value: no Journal or
/// board access happens inside the renderer, so the caller (``FeatureBranchPullRequest``) is the one
/// place that reads the Journal and the board.
public struct PullRequestBodyCard: Equatable, Sendable {
    public let title: String
    public let repository: String
    public let state: CardState
    /// A short summary of the routes attempted, e.g. "cli-a/model-x (2 attempts)".
    public let routeSummary: String
    /// A short summary of check results, e.g. "checks: 1 passed".
    public let checkSummary: String
    public let roundCount: Int
    /// Set when `state` is `.blocked`.
    public let blockReason: String?
    /// Set when `state` is `.waitingOnYou`.
    public let waitingReason: WaitingReason?
    /// Whether this Card is the lane hole: authored but never run because an earlier Card in its lane
    /// blocked or went Waiting on You.
    public let isLaneHole: Bool
    /// Whether this Card is carried forward from a predecessor Feature (Adoption).
    public let carriedForward: Bool

    public init(
        title: String, repository: String, state: CardState, routeSummary: String, checkSummary: String,
        roundCount: Int, blockReason: String? = nil, waitingReason: WaitingReason? = nil,
        isLaneHole: Bool = false, carriedForward: Bool = false
    ) {
        self.title = title
        self.repository = repository
        self.state = state
        self.routeSummary = routeSummary
        self.checkSummary = checkSummary
        self.roundCount = roundCount
        self.blockReason = blockReason
        self.waitingReason = waitingReason
        self.isLaneHole = isLaneHole
        self.carriedForward = carriedForward
    }

    /// Whether this Card counts as one of the Cycle's incomplete Cards for a Partial Landing.
    public var isIncomplete: Bool {
        state == .blocked || state == .waitingOnYou
    }
}

/// One unmet Definition of Done clause, quoted with its Spec Citation location (roadmap P10.4).
public struct PullRequestBodyUnmetClause: Equatable, Sendable {
    public let workCardTitle: String
    public let text: String
    public let citation: String

    public init(workCardTitle: String, text: String, citation: String) {
        self.workCardTitle = workCardTitle
        self.text = text
        self.citation = citation
    }
}

/// The Mainline Conflict verdict a pull request body reports for its own Repo Lane.
public struct PullRequestBodyMergeVerdict: Equatable, Sendable {
    public let conflict: Bool
    public let untestable: Bool
    public let paths: [String]
    public let mainlineRef: String?
    public let mainlineCommit: String?

    public init(
        conflict: Bool, untestable: Bool, paths: [String] = [], mainlineRef: String? = nil,
        mainlineCommit: String? = nil
    ) {
        self.conflict = conflict
        self.untestable = untestable
        self.paths = paths
        self.mainlineRef = mainlineRef
        self.mainlineCommit = mainlineCommit
    }
}

/// Everything a pull request body's rendering needs, gathered by the caller. Pure: the renderer that
/// consumes this touches no Journal and no board.
public struct PullRequestBodyInput: Equatable, Sendable {
    public let featureTitle: String
    public let featureIssueURL: String?
    public let nightID: Int64
    public let nightTimestamp: String
    public let repository: String
    /// N: the repositories that pushed a Feature Branch, so open a pull request (not the touched ones: a
    /// repository with a No-Pushed-Branch Outcome opens none).
    public let pushedRepositoryCount: Int
    public let mergedCount: Int
    /// Every Card of the Feature's Cycle, across every repository — a Partial Landing must list every
    /// repository's incomplete Cards, not only this lane's.
    public let cycleCards: [PullRequestBodyCard]
    public let mergeVerdict: PullRequestBodyMergeVerdict
    /// The Definition of Done clauses to list as unmet when there is no ``verificationReport``.
    public let unmetClauses: [PullRequestBodyUnmetClause]
    /// The Feature's Verification report (roadmap P10.5), when Verification ran before this body was
    /// written. When present the body carries it with its limitation, and the unmet list is derived
    /// from it (``effectiveUnmetClauses``) so the two cannot disagree; when nil the body is unchanged.
    public let verificationReport: VerificationReport?
    /// Issue id → display name (a Card's title, or the Feature Issue's), for
    /// ``effectiveUnmetClauses`` to resolve the report's issue ids by (issue #161; spec:
    /// landing/announce-a-partial-landing). An id missing from this lookup renders as itself.
    public let workCardTitles: [String: String]
    /// The repositories with a No-Pushed-Branch Outcome, shown as `[no pull request: <repo>]` notes beside
    /// the Partial Landing's Roll-up sentence (roadmap P19.7; risks OQ108). A complete landing has no
    /// Roll-up sentence, so it renders none.
    public let noPullRequestRepositories: [String]

    public init(
        featureTitle: String, featureIssueURL: String?, nightID: Int64, nightTimestamp: String,
        repository: String, pushedRepositoryCount: Int, mergedCount: Int,
        cycleCards: [PullRequestBodyCard], mergeVerdict: PullRequestBodyMergeVerdict,
        unmetClauses: [PullRequestBodyUnmetClause], verificationReport: VerificationReport? = nil,
        workCardTitles: [String: String] = [:], noPullRequestRepositories: [String] = []
    ) {
        self.featureTitle = featureTitle
        self.featureIssueURL = featureIssueURL
        self.nightID = nightID
        self.nightTimestamp = nightTimestamp
        self.repository = repository
        self.pushedRepositoryCount = pushedRepositoryCount
        self.mergedCount = mergedCount
        self.cycleCards = cycleCards
        self.mergeVerdict = mergeVerdict
        self.unmetClauses = unmetClauses
        self.verificationReport = verificationReport
        self.workCardTitles = workCardTitles
        self.noPullRequestRepositories = noPullRequestRepositories
    }

    /// The unmet list the body prints: every clause the report did not find `met` (unmet and
    /// unresolved) when there is a report, else the caller's own ``unmetClauses``.
    public var effectiveUnmetClauses: [PullRequestBodyUnmetClause] {
        guard let verificationReport else { return unmetClauses }
        return verificationReport.unmetOrUnresolved.map {
            PullRequestBodyUnmetClause(
                workCardTitle: workCardTitles[$0.issueID] ?? $0.issueID, text: $0.text, citation: $0.locationID
            )
        }
    }

    /// Every incomplete Card of the whole Cycle (any repository), Blocked or Waiting on You.
    public var incompleteCards: [PullRequestBodyCard] {
        cycleCards.filter(\.isIncomplete)
    }

    /// This repository's own Cards, in authored order as given.
    public var laneCards: [PullRequestBodyCard] {
        cycleCards.filter { $0.repository == repository }
    }

    public var isPartialLanding: Bool {
        !incompleteCards.isEmpty
    }
}

/// Renders a Repo Lane's pull request body (roadmap P10.4; spec: landing/open-one-pull-request-
/// per-repository, landing/announce-a-partial-landing). Pure: a value in, a `String` out, no Journal
/// or board access. Never renders model-authored content (diffs, verdict prose, briefs).
public enum PullRequestBody {
    public static func render(_ input: PullRequestBodyInput) -> String {
        input.isPartialLanding ? renderPartial(input) : renderComplete(input)
    }

    // MARK: - Complete landing

    private static func renderComplete(_ input: PullRequestBodyInput) -> String {
        var lines: [String] = []
        lines.append("Feature: \(input.featureTitle)")
        lines.append("")
        lines.append("This pull request carries this repository's (`\(input.repository)`) Cards for the Feature.")
        lines.append("")
        lines.append(cardListSection(title: "Cards in this repository", cards: input.laneCards))
        lines.append("")
        if let report = input.verificationReport {
            lines.append(report.markdownSection())
            lines.append("")
        }
        lines.append(
            "Merging this pull request is what releases the next Feature; leaving it open costs tomorrow night."
        )
        lines.append("")
        lines.append(mainlineVerdictLine(input))
        lines.append("")
        lines.append(featurePointerLine(input))
        return lines.joined(separator: "\n")
    }

    // MARK: - Partial Landing

    private static func renderPartial(_ input: PullRequestBodyInput) -> String {
        let incomplete = input.incompleteCards
        let waitingCount = incomplete.filter { $0.state == .waitingOnYou }.count
        let blockedCount = incomplete.filter { $0.state == .blocked }.count
        let landedCount = input.cycleCards.filter { $0.state == .done }.count
        let totalCardCount = input.cycleCards.count
        let uCount = input.effectiveUnmetClauses.count
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
            landedCount: landedCount, totalCardCount: totalCardCount, uCount: uCount,
            carriedCount: incomplete.count, input: input
        ))
        lines.append(stampLine(input))
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
    /// Roll-up lattice's own worst-first rule (`needs you` before `blocked`).
    private static func openingLine1(
        waitingCount: Int, blockedCount: Int, landedCount: Int, totalCardCount: Int, input: PullRequestBodyInput
    ) -> String {
        let dispositionWord = waitingCount > 0
            ? "\(waitingCount) waiting on you"
            : "\(blockedCount) blocked"
        let notes = input.noPullRequestRepositories.isEmpty
            ? "" : " " + FeatureRollUp.noPullRequestNotes(input.noPullRequestRepositories)
        return "**partial landing · \(landedCount) of \(totalCardCount) Cards landed · "
            + "0 of \(input.pushedRepositoryCount) merged · \(dispositionWord)**" + notes
    }

    private static func openingLine2(
        landedCount: Int, totalCardCount: Int, uCount: Int, carriedCount: Int, input: PullRequestBodyInput
    ) -> String {
        "This pull request is 1 of \(input.pushedRepositoryCount) for Feature '\(input.featureTitle)'. "
            + "Merging all \(input.pushedRepositoryCount) pull requests closes the Feature unverified and "
            + "archives its Cycle; merging fewer than \(input.pushedRepositoryCount) closes nothing and "
            + "releases nothing. \(landedCount) of \(totalCardCount) Cards landed; "
            + "\(uCount) Definition of Done clauses remain "
            + "unmet; \(carriedCount) unfinished Cards are carried forward and auto-Blocked awaiting Adoption."
    }

    private static func stampLine(_ input: PullRequestBodyInput) -> String {
        let link = input.featureIssueURL.map { "[Linear Feature Issue](\($0))" } ?? "Linear Feature Issue"
        return "*As of Night \(input.nightID) (\(input.nightTimestamp)). Live state: \(link)*"
    }

    private static func featurePointerLine(_ input: PullRequestBodyInput) -> String {
        let link = input.featureIssueURL.map { "[Feature card](\($0))" } ?? "the Feature card"
        return "See \(link) for the live version of this Feature."
    }

    private static func incompleteCardsSection(_ cards: [PullRequestBodyCard]) -> String {
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

    private static func unmetClausesSection(_ clauses: [PullRequestBodyUnmetClause]) -> String {
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

    private static func carriedForwardSection(_ cards: [PullRequestBodyCard]) -> String {
        guard !cards.isEmpty else { return "Carried forward: none." }
        var lines = ["Carried forward (Waiting on You, auto-Blocked awaiting Adoption):"]
        for card in cards {
            lines.append("- \(card.title) [\(card.repository)]")
        }
        return lines.joined(separator: "\n")
    }

    private static func cardListSection(title: String, cards: [PullRequestBodyCard]) -> String {
        guard !cards.isEmpty else { return "\(title): none." }
        var lines = ["\(title):"]
        for card in cards {
            lines.append(
                "- \(card.title): route \(card.routeSummary); \(card.checkSummary); \(card.roundCount) round(s)"
            )
        }
        return lines.joined(separator: "\n")
    }

    /// Never worded as safe to merge: a clean verdict is a textual test against a named
    /// remote-tracking ref as of a Night, and nothing more.
    private static func mainlineVerdictLine(_ input: PullRequestBodyInput) -> String {
        let verdict = input.mergeVerdict
        if verdict.untestable {
            return "Mainline Conflict verdict: untestable as of Night \(input.nightID)."
        }
        let against = againstClause(verdict)
        if verdict.conflict {
            let paths = verdict.paths.joined(separator: ", ")
            return "Mainline Conflict as of Night \(input.nightID): \(paths)\(against)."
        }
        return "Mainline Conflict verdict as of Night \(input.nightID): this is a textual test" + against
            + "; it is not a claim that merging is safe."
    }

    private static func againstClause(_ verdict: PullRequestBodyMergeVerdict) -> String {
        guard let ref = verdict.mainlineRef else { return "" }
        let commitSuffix = verdict.mainlineCommit.map { " at \($0)" } ?? ""
        return " against \(ref)" + commitSuffix
    }
}
