import Domain
import Foundation
import Journal

/// One Verification's clause-by-clause report (roadmap P10.5; spec: verification/verify-a-feature-clause-
/// by-clause). Pure: a value built from the Journal's recorded Verification, rendered for the two places
/// Triage happens — the Feature card's Managed Block and each pull request body — with no Journal or
/// board access. It states no aggregate: there is no "passed", "verified" or "failed" headline, and no
/// counts line that could read as one.
public struct VerificationReport: Equatable, Sendable {
    /// The prefix every Managed Block line of this report starts with, so one
    /// ``BoardWrite/updateManagedBlockLine(issue:prefix:line:)`` replaces the whole report.
    public static let managedBlockPrefix = "Verification: "

    /// The story's limitation statement, shown next to the report wherever it is.
    public static let limitation =
        "Known limitation: this makes the check auditable, not sound. It does not catch a specification that "
        + "is wrong or thin, a Feature that is correct clause by clause and incoherent as a whole, or which "
        + "Feature was selected in the first place."

    /// What the limitation adds when the Feature touches more than one repository (OQ197; spec:
    /// verification/verify-a-feature-clause-by-clause `#report-limitation`): the Checks ran apart.
    public static let separateChecksSentence =
        "Each Check ran in its own repository; this report does not show which commits of the other "
        + "repositories a Check used, so it is not evidence that they were tested together."

    /// The clauses, Feature-level first and then Cards in authored order, as recorded.
    public let clauses: [ClauseVerificationRecord]
    /// Per repository, the checkout the Verification judged, as recorded (OQ191 item 3). Empty for a record
    /// written before that rule: the report then says "judged commit not recorded" and names no commit.
    public let judgedCheckouts: [JudgedCheckout]
    /// How many repositories the Feature touches (`touched_repos`, as recorded at selection; not N, and not
    /// the repositories with a judged checkout). More than one adds ``separateChecksSentence`` to the limitation.
    public let touchedRepositoryCount: Int

    public init(
        clauses: [ClauseVerificationRecord], judgedCheckouts: [JudgedCheckout] = [], touchedRepositoryCount: Int = 1
    ) {
        self.clauses = clauses
        self.judgedCheckouts = judgedCheckouts
        self.touchedRepositoryCount = touchedRepositoryCount
    }

    public init(record: FeatureVerificationRecord, touchedRepositoryCount: Int = 1) {
        self.init(
            clauses: record.clauses, judgedCheckouts: record.judgedCheckouts,
            touchedRepositoryCount: touchedRepositoryCount
        )
    }

    /// The limitation stated beside this report on every surface: ``limitation``, followed by
    /// ``separateChecksSentence`` when the Feature touches more than one repository (OQ197).
    public var limitationStatement: String {
        Self.limitationStatement(touchedRepositoryCount: touchedRepositoryCount)
    }

    /// The limitation for a Feature touching `touchedRepositoryCount` repositories: unchanged for one.
    public static func limitationStatement(touchedRepositoryCount: Int) -> String {
        touchedRepositoryCount > 1 ? limitation + " " + separateChecksSentence : limitation
    }

    /// The clauses that are `unmet` or `unresolved`: what the Feature is returned holding.
    public var unmetOrUnresolved: [ClauseVerificationRecord] {
        clauses.filter { $0.verdict == .unmet || $0.verdict == .unresolved }
    }

    /// The clauses whose check could not be performed in this environment.
    public var notChecked: [ClauseVerificationRecord] {
        clauses.filter { $0.verdict == .notChecked }
    }

    // MARK: - Line

    /// `cid · clause text · Spec Citation (<location_id>) · [provenance] · verdict · what was checked ·
    /// interpretation verified under`. The `cid` is prefixed with its issue id: clause ids are unique
    /// only within one issue. A clause whose text or citation was edited on the board after authoring
    /// says so in its text field.
    public static func line(for clause: ClauseVerificationRecord) -> String {
        let text = clause.invalidatedCause.map { "\(clause.text) (invalidated: \($0))" } ?? clause.text
        let fields = [
            "\(clause.issueID) \(clause.cid)",
            text,
            "Spec Citation (\(clause.locationID))",
            "[\(clause.citationProvenance)]",
            clause.verdict.rawValue,
            clause.whatWasChecked,
            clause.interpretation
        ]
        return fields.map(singleLine).joined(separator: " · ")
    }

    /// A field can never break the one-line-per-clause shape, whatever text it carries.
    private static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    // MARK: - Managed Block

    /// The Managed Block variant: a header, one line per clause and the limitation, every line starting
    /// with ``managedBlockPrefix``. Newline-joined, for one `updateManagedBlockLine`.
    public func managedBlockLines() -> String {
        let prefix = Self.managedBlockPrefix
        var lines = [
            prefix + "Definition of Done, clause by clause (Feature-level clauses first, then Cards in authored order)"
        ]
        lines += clauses.map { prefix + Self.line(for: $0) }
        lines.append(prefix + limitationStatement)
        return lines.joined(separator: "\n")
    }

    // MARK: - Pull request body

    /// The pull request body variant: a Markdown section, the judged commits first, then the clauses, the
    /// limitation beneath them.
    public func markdownSection() -> String {
        var lines = ["## Verification, clause by clause", "", judgedCommitsLine(), ""]
        lines += clauses.map { "- " + Self.line(for: $0) }
        lines.append("")
        lines.append(limitationStatement)
        return lines.joined(separator: "\n")
    }

    /// One line naming, per repository, the short commit the Verification judged, a No-Pushed-Branch
    /// repository marked "no pushed branch" (spec: landing/open-one-pull-request-per-repository,
    /// `#judged-commit-in-body`; OQ191 items 3 and 5). It states the judged commit only: it is never compared
    /// with the pull request head. A record written before that rule says "judged commit not recorded", and
    /// no commit is taken from anywhere else in its place.
    public func judgedCommitsLine() -> String {
        guard !judgedCheckouts.isEmpty else { return "Judged commits: judged commit not recorded" }
        let entries = judgedCheckouts.map { checkout in
            let entry = "\(checkout.repository) `\(checkout.commit.prefix(7))`"
            return checkout.noPushedBranch ? entry + " (no pushed branch)" : entry
        }
        return "Judged commits: " + entries.joined(separator: " · ")
    }
}
