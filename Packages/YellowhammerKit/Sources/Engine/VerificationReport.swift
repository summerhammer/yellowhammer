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

    /// The clauses, Feature-level first and then Cards in authored order, as recorded.
    public let clauses: [ClauseVerificationRecord]

    public init(clauses: [ClauseVerificationRecord]) {
        self.clauses = clauses
    }

    public init(record: FeatureVerificationRecord) {
        self.init(clauses: record.clauses)
    }

    /// The clauses that are not `met`: what the Feature is returned holding.
    public var unmetOrUnresolved: [ClauseVerificationRecord] {
        clauses.filter { $0.verdict != .met }
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
        lines.append(prefix + Self.limitation)
        return lines.joined(separator: "\n")
    }

    // MARK: - Pull request body

    /// The pull request body variant: a Markdown section, the limitation beneath it.
    public func markdownSection() -> String {
        var lines = ["## Verification, clause by clause", ""]
        lines += clauses.map { "- " + Self.line(for: $0) }
        lines.append("")
        lines.append(Self.limitation)
        return lines.joined(separator: "\n")
    }
}
