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
    /// The display title of the Work Card this Card is held behind (spec ruling OQ182, item 4), nil
    /// when this Card is not held. Set only on a Todo Card.
    public let heldBehindTitle: String?

    public init(
        title: String, repository: String, state: CardState, routeSummary: String, checkSummary: String,
        roundCount: Int, blockReason: String? = nil, waitingReason: WaitingReason? = nil,
        isLaneHole: Bool = false, carriedForward: Bool = false, heldBehindTitle: String? = nil
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
        self.heldBehindTitle = heldBehindTitle
    }

    /// Whether this Card counts as one of the Cycle's incomplete Cards for a Partial Landing: Blocked,
    /// Waiting on You, or a Todo Card held behind a not-Done same-repository predecessor (spec ruling
    /// OQ182, item 4).
    public var isIncomplete: Bool {
        state == .blocked || state == .waitingOnYou || heldBehindTitle != nil
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
    /// the Partial Landing's Roll-up sentence (roadmap P19.7; risks OQ108). A complete landing's Roll-up
    /// opening carries its own notes, so it renders none here.
    public let noPullRequestRepositories: [String]
    /// Set on a stacked pull request (spec `#stack-notice`): the notice follows the Roll-up opening directly,
    /// before any other content. Nil on a pull request against the default branch.
    public let stackNotice: PullRequestStackNotice?
    /// The Feature Card's bold Roll-up line (sentence plus its beside-notes) as of the Night that wrote it. A
    /// complete landing's body opens with it (OQ31; sponsor ruling 2026-10-21, Q3); a Partial Landing renders its
    /// own fixed Lines 1-2 instead, so ignores it. Nil renders no opening.
    public let rollUpOpening: String?

    public init(
        featureTitle: String, featureIssueURL: String?, nightID: Int64, nightTimestamp: String,
        repository: String, pushedRepositoryCount: Int, mergedCount: Int,
        cycleCards: [PullRequestBodyCard], mergeVerdict: PullRequestBodyMergeVerdict,
        unmetClauses: [PullRequestBodyUnmetClause], verificationReport: VerificationReport? = nil,
        workCardTitles: [String: String] = [:], noPullRequestRepositories: [String] = [],
        stackNotice: PullRequestStackNotice? = nil, rollUpOpening: String? = nil
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
        self.stackNotice = stackNotice
        self.rollUpOpening = rollUpOpening
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
    /// What merging a verified Feature's pull request releases (spec: landing/open-one-pull-request-per-
    /// repository `#any-merge-method`; OQ177, OQ190 item 3): its slot in the Unmerged Feature Stack and any Feature
    /// waiting on it. It leads with the sentence the Night Card shares (``MergeRouteOut/anyMethod``), recommends no
    /// merge method, and does not carry the Night Card's route out.
    static let releaseSentence = MergeRouteOut.anyMethod
        + " It clears this Feature's slot in the unmerged Feature stack (`unmerged_features_max`) and releases any "
        + "downstream Features waiting on it. Leaving it open costs tomorrow night."

    public static func render(_ input: PullRequestBodyInput) -> String {
        input.isPartialLanding ? renderPartial(input) : renderComplete(input)
    }

    // MARK: - Complete landing

    /// A complete landing's body opens with the bold Roll-up sentence, the stack notice follows directly after it
    /// on a stacked pull request, before any other content. Unlike a Partial Landing it carries no As-of stamp:
    /// the ruling names the stamp for the Partial Landing only.
    private static func renderComplete(_ input: PullRequestBodyInput) -> String {
        var lines: [String] = []
        if let opening = input.rollUpOpening {
            lines.append(opening)
            lines.append("")
        }
        if let notice = input.stackNotice {
            lines.append(notice.rendered)
            lines.append("")
        }
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
        lines.append(releaseSentence)
        lines.append("")
        lines.append(mainlineVerdictLine(input))
        lines.append("")
        lines.append(featurePointerLine(input))
        return lines.joined(separator: "\n")
    }

    static func featurePointerLine(_ input: PullRequestBodyInput) -> String {
        let link = input.featureIssueURL.map { "[Feature Card](\($0))" } ?? "the Feature Card"
        return "See \(link) for the live version of this Feature."
    }

    static func cardListSection(title: String, cards: [PullRequestBodyCard]) -> String {
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
    static func mainlineVerdictLine(_ input: PullRequestBodyInput) -> String {
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
