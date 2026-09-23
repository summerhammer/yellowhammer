import Domain
import Foundation
import Journal

/// The comment posted on a Feature Issue when it is returned for unmet or unresolved clauses (roadmap
/// P10.6; spec: verification/return-a-feature-with-unmet-clauses). Pure: built from the Cycle's recorded
/// Verification and its recorded pull requests, with no Journal or board access. Per-clause only — no
/// aggregate "passed/failed" headline and no counts line, the same discipline as ``VerificationReport``.
public struct FeatureReturnComment: Equatable, Sendable {
    public let clauses: [ClauseVerificationRecord]
    /// Every pull request recorded for this Feature, keyed by repository.
    public let pullRequests: [String: PullRequestRecord]

    public init(clauses: [ClauseVerificationRecord], pullRequests: [String: PullRequestRecord]) {
        self.clauses = clauses
        self.pullRequests = pullRequests
    }

    public init(record: FeatureVerificationRecord, pullRequests: [String: PullRequestRecord]) {
        self.init(clauses: record.clauses, pullRequests: pullRequests)
    }

    private var unmet: [ClauseVerificationRecord] { clauses.filter { $0.verdict == .unmet } }
    private var unresolved: [ClauseVerificationRecord] { clauses.filter { $0.verdict == .unresolved } }
    private var met: [ClauseVerificationRecord] { clauses.filter { $0.verdict == .met } }

    /// The comment body: an opening statement of the disposition, then unmet, unresolved and met clauses
    /// (a section omitted when it has nothing to list), then the pull requests still open, then the
    /// story's limitation statement.
    public func body() -> String {
        var lines = [
            "This Feature is returned to the Operator: Verification could not confirm every clause of its " +
                "Definition of Done. It is not Done, and its Cycle is not archived."
        ]

        if !unmet.isEmpty {
            lines.append("")
            lines.append("## Unmet clauses")
            lines += unmet.map { "- " + VerificationReport.line(for: $0) }
        }

        if !unresolved.isEmpty {
            lines.append("")
            lines.append(
                "## Unresolved clauses (citations for the Specification Author to repair, not unfinished work)"
            )
            lines += unresolved.map { "- " + VerificationReport.line(for: $0) }
        }

        if !met.isEmpty {
            lines.append("")
            lines.append("## Met clauses")
            lines += met.map { "- " + VerificationReport.line(for: $0) }
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
        lines.append(VerificationReport.limitation)
        return lines.joined(separator: "\n")
    }
}
