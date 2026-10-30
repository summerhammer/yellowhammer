import Domain
import Foundation
import Journal

/// The comment posted on a Feature Issue when it is returned for unmet or unresolved clauses (roadmap
/// P10.6; spec: verification/return-a-feature-with-unmet-clauses). Pure: built from the Cycle's recorded
/// Verification and its recorded pull requests, with no Journal or board access. Per-clause only — no
/// aggregate "passed/failed" headline and no counts line, the same discipline as ``VerificationReport``.
public struct FeatureReturnComment: Equatable, Sendable {
    /// Information needed to render an issue identifier and optional link on Linear.
    public struct IssueDisplay: Equatable, Sendable {
        public let identifier: String?
        public let title: String?
        public let url: String?

        public init(identifier: String? = nil, title: String? = nil, url: String? = nil) {
            self.identifier = identifier
            self.title = title
            self.url = url
        }

        public init(card: CardRecord) {
            self.init(
                identifier: card.issueIDForDisplay ?? card.issueKey,
                title: card.title,
                url: card.issueURL
            )
        }

        public init(feature: FeatureRecord) {
            self.init(
                identifier: feature.issueIDForDisplay ?? feature.issueKey,
                title: nil,
                url: feature.issueURL
            )
        }

        func rendered(fallback: String) -> String {
            let text: String
            if let identifier, !identifier.isEmpty {
                text = identifier
            } else if let title, !title.isEmpty {
                text = title
            } else {
                text = fallback
            }
            if let url, !url.isEmpty {
                return "[\(text)](\(url))"
            }
            return text
        }
    }

    public let clauses: [ClauseVerificationRecord]
    /// Every pull request recorded for this Feature, keyed by repository.
    public let pullRequests: [String: PullRequestRecord]
    public let issues: [String: IssueDisplay]
    /// The repositories that declared `check = none`: why a `not checked` build or test clause had no Check.
    public let noCheckRepositories: [String]
    /// How many repositories the Feature touches (`touched_repos`): more than one adds the separate-Checks
    /// sentence to the limitation (OQ197), as beside the report on the Managed Block.
    public let touchedRepositoryCount: Int

    public init(
        clauses: [ClauseVerificationRecord],
        pullRequests: [String: PullRequestRecord],
        issues: [String: IssueDisplay] = [:],
        noCheckRepositories: [String] = [],
        touchedRepositoryCount: Int = 1
    ) {
        self.clauses = clauses
        self.pullRequests = pullRequests
        self.issues = issues
        self.noCheckRepositories = noCheckRepositories
        self.touchedRepositoryCount = touchedRepositoryCount
    }

    public init(
        record: FeatureVerificationRecord,
        pullRequests: [String: PullRequestRecord],
        issues: [String: IssueDisplay] = [:]
    ) {
        self.init(clauses: record.clauses, pullRequests: pullRequests, issues: issues)
    }

    public init(
        record: FeatureVerificationRecord,
        pullRequests: [String: PullRequestRecord],
        feature: FeatureRecord,
        cards: [CardRecord] = [],
        noCheckRepositories: [String] = [],
        touchedRepositoryCount: Int = 1
    ) {
        var issues: [String: IssueDisplay] = [:]
        issues[feature.issueID] = IssueDisplay(feature: feature)
        for card in cards {
            issues[card.issueID] = IssueDisplay(card: card)
        }
        self.init(
            clauses: record.clauses, pullRequests: pullRequests, issues: issues,
            noCheckRepositories: noCheckRepositories, touchedRepositoryCount: touchedRepositoryCount
        )
    }

    private struct UniqueClauseKey: Hashable {
        let locationID: String
        let text: String
    }

    /// Deduplicates clauses so each Definition of Done clause is listed exactly once.
    /// Prefers Feature-level when present; otherwise keeps the first occurrence.
    /// Merges verdicts: `.unmet` > `.unresolved` > `.notChecked` > `.met`.
    private var groupedClauses: [ClauseVerificationRecord] {
        var orderedKeys: [UniqueClauseKey] = []
        var map: [UniqueClauseKey: ClauseVerificationRecord] = [:]

        for clause in clauses {
            let key = UniqueClauseKey(locationID: clause.locationID, text: clause.text)
            if let existing = map[key] {
                let verdict: ClauseVerdict
                if existing.verdict == .unmet || clause.verdict == .unmet {
                    verdict = .unmet
                } else if existing.verdict == .unresolved || clause.verdict == .unresolved {
                    verdict = .unresolved
                } else if existing.verdict == .notChecked || clause.verdict == .notChecked {
                    verdict = .notChecked
                } else {
                    verdict = .met
                }

                let decidingClause: ClauseVerificationRecord?
                if existing.verdict == .unmet {
                    decidingClause = existing
                } else if clause.verdict == .unmet {
                    decidingClause = clause
                } else if existing.verdict == .unresolved {
                    decidingClause = existing
                } else if clause.verdict == .unresolved {
                    decidingClause = clause
                } else if existing.verdict == .notChecked {
                    decidingClause = existing
                } else if clause.verdict == .notChecked {
                    decidingClause = clause
                } else {
                    decidingClause = nil
                }

                let preferred = (clause.level == "feature" && existing.level != "feature") ? clause : existing
                let reportingClause = decidingClause ?? preferred
                map[key] = ClauseVerificationRecord(
                    issueID: preferred.issueID,
                    cid: preferred.cid,
                    level: (existing.level == "feature" || clause.level == "feature") ? "feature" : preferred.level,
                    text: preferred.text,
                    locationID: preferred.locationID,
                    citationProvenance: preferred.citationProvenance,
                    verdict: verdict,
                    whatWasChecked: reportingClause.whatWasChecked,
                    interpretation: reportingClause.interpretation,
                    judgedBy: reportingClause.judgedBy,
                    invalidatedCause: preferred.invalidatedCause ?? clause.invalidatedCause ?? existing.invalidatedCause
                )
            } else {
                orderedKeys.append(key)
                map[key] = clause
            }
        }

        return orderedKeys.compactMap { map[$0] }
    }

    private var unmet: [ClauseVerificationRecord] { groupedClauses.filter { $0.verdict == .unmet } }
    private var unresolved: [ClauseVerificationRecord] { groupedClauses.filter { $0.verdict == .unresolved } }
    private var notChecked: [ClauseVerificationRecord] { groupedClauses.filter { $0.verdict == .notChecked } }
    private var met: [ClauseVerificationRecord] { groupedClauses.filter { $0.verdict == .met } }

    /// One clause as a heading bullet (level, issue, cid) with a labelled sub-bullet per field, so the
    /// requirement, its citation, the verdict and the reasoning are separable at a glance. A multi-line
    /// field keeps its line breaks, each continuation line indented under its label.
    private func lines(for clause: ClauseVerificationRecord) -> [String] {
        let level = clause.level == "feature" ? "Feature" : "Work Card"
        let issueDisplay = issues[clause.issueID]?.rendered(fallback: clause.issueID) ?? clause.issueID
        let text = clause.invalidatedCause.map { "\(clause.text) (invalidated: \($0))" } ?? clause.text
        let fields: [(label: String, value: String)] = [
            ("Clause", text),
            ("Spec citation", "`\(clause.locationID)` · \(clause.citationProvenance)"),
            ("Verdict", clause.verdict.rawValue),
            ("Checked", clause.whatWasChecked),
            ("Interpretation", clause.interpretation)
        ]
        var result = ["- **\(level)** \(issueDisplay) · `\(clause.cid)`"]
        for field in fields {
            let valueLines = Self.nonBlankLines(field.value)
            result.append("  - **\(field.label):** " + (valueLines.first ?? ""))
            result += valueLines.dropFirst().map { "    " + $0 }
        }
        return result
    }

    private static func nonBlankLines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func section(_ heading: String, _ clauses: [ClauseVerificationRecord]) -> [String] {
        [""] + [heading] + clauses.flatMap { lines(for: $0) }
    }

    /// The comment body: an opening statement of the disposition, then unmet, unresolved, not checked and met clauses
    /// (a section omitted when it has nothing to list), then the pull requests still open, then the
    /// story's limitation statement.
    public func body() -> String {
        var lines = [
            "This Feature is returned to the Operator: Verification could not confirm every clause of its " +
                "Definition of Done. It is not Done, and its Cycle is not archived."
        ]

        if !unmet.isEmpty {
            lines += section("## Unmet clauses (\(unmet.count))", unmet)
        }

        if !unresolved.isEmpty {
            lines += section(
                "## Unresolved clauses (citations for the Specification Author to repair, not unfinished work)",
                unresolved
            )
        }

        if !notChecked.isEmpty {
            let reason = NoCheckAttribution.headingNote(repositories: noCheckRepositories)
            lines += section(
                "## Not checked clauses (checks that never ran, not unfinished work"
                    + (reason.map { "; \($0)" } ?? "") + ")",
                notChecked
            )
        }

        if !met.isEmpty {
            lines += section("## Met clauses (\(met.count))", met)
        }

        lines.append("")
        lines.append("## Pull requests")
        if pullRequests.isEmpty {
            lines.append("- none was opened")
        } else {
            for repository in pullRequests.keys.sorted() {
                let record = pullRequests[repository]!
                let location = record.url ?? "link not recorded"
                lines.append("- \(repository): \(location), still open")
            }
        }

        lines.append("")
        lines.append(VerificationReport.limitationStatement(touchedRepositoryCount: touchedRepositoryCount))
        return lines.joined(separator: "\n")
    }
}
