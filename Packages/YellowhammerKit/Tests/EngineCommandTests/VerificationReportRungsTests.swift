import Domain
@testable import Engine
import Foundation
@testable import Journal
import Testing

// issue #670 (board-projection/maintain-the-managed-block, budget on rewrite; verification/verify-a-feature-
// clause-by-clause): the report's compaction ladder keeps the report per clause on every rung. Rendering only.

private func clause(
    _ issue: String, _ cid: String, verdict: ClauseVerdict = .met, touchedLong: Bool = true
) -> ClauseVerificationRecord {
    ClauseVerificationRecord(
        issueID: issue, cid: cid, level: "card", text: "Clause text of \(cid) " + (touchedLong ? "xxxxxxxxxx " : ""),
        locationID: "epic/story", citationProvenance: "machine-found", verdict: verdict,
        whatWasChecked: "CHECKED-" + String(repeating: "c", count: touchedLong ? 300 : 1),
        interpretation: "READ-" + String(repeating: "r", count: touchedLong ? 300 : 1),
        judgedBy: .agent, invalidatedCause: nil
    )
}

private let report = VerificationReport(clauses: [
    clause("FEAT-1", "c1"),
    clause("BACK-1", "c1", verdict: .unmet),
    clause("BACK-1", "c2", verdict: .notChecked)
], touchedRepositoryCount: 2)

@Suite("Verification report: Managed Block compaction ladder (#670)")
struct VerificationReportRungsTests {
    private var rungs: [[String]] {
        report.managedBlockRenderings().map {
            $0.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        }
    }

    @Test("Rung 1 is the full report, and there are three rungs")
    func rungOneIsTheFullReport() {
        let renderings = report.managedBlockRenderings()
        #expect(renderings.count == 3)
        #expect(renderings[0] == report.managedBlockLines())
    }

    @Test("Every line of every rung starts with the prefix, and the limitation is the last line")
    func prefixAndLimitation() {
        for lines in rungs {
            #expect(lines.allSatisfy { $0.hasPrefix(VerificationReport.managedBlockPrefix) })
            #expect(lines.last == VerificationReport.managedBlockPrefix + report.limitationStatement)
        }
        #expect(report.limitationStatement.contains("Each Check ran in its own repository"))
    }

    @Test("Every rung lists every clause with its verdict, and states no aggregate")
    func perClauseOnEveryRung() {
        for rendering in report.managedBlockRenderings() {
            for clause in report.clauses {
                let expected = "\(clause.issueID) \(clause.cid)"
                let line = rendering.split(separator: "\n").first { $0.contains(expected) }
                #expect(line?.contains(clause.verdict?.rawValue ?? "dropped") == true)
            }
            #expect(!rendering.contains("passed"))
            #expect(!rendering.contains("3 met"))
        }
    }

    @Test("Rung 2 drops what was checked and the interpretation, keeps text, citation and provenance")
    func rungTwo() {
        let rung = report.managedBlockRenderings()[1]
        #expect(!rung.contains("CHECKED-"))
        #expect(!rung.contains("READ-"))
        #expect(rung.contains("Clause text of c1"))
        #expect(rung.contains("Spec Citation (epic/story)"))
        #expect(rung.contains("[machine-found]"))
        #expect(rung.contains("Compacted to fit the description budget"))
        #expect(rung.contains("full report stays in the Journal"))
        #expect(rung.contains("pull request"))
    }

    @Test("Rung 3 is the id and verdict only")
    func rungThree() {
        let rung = report.managedBlockRenderings()[2]
        #expect(!rung.contains("Clause text of"))
        #expect(!rung.contains("Spec Citation (epic/story)"))
        #expect(!rung.contains("[machine-found]"))
        #expect(!rung.contains("CHECKED-"))
        #expect(rung.contains("Verification: BACK-1 c1 · unmet\n"))
        #expect(rung.contains("full report stays in the Journal"))
    }

    @Test("Each rung is strictly shorter than the one before for long fields")
    func strictlyShrinking() {
        let lengths = report.managedBlockRenderings().map(\.utf16.count)
        #expect(lengths[0] > lengths[1])
        #expect(lengths[1] > lengths[2])
    }

    @Test("A field with newlines never breaks the one-line shape on a compacted rung")
    func newlinesCollapse() {
        let messy = VerificationReport(clauses: [
            ClauseVerificationRecord(
                issueID: "BACK-1", cid: "c1", level: "card", text: "First\nSecond", locationID: "e/s",
                citationProvenance: "machine-found", verdict: .met, whatWasChecked: "a\nb", interpretation: "c\nd",
                judgedBy: .agent, invalidatedCause: nil
            )
        ])
        for rendering in messy.managedBlockRenderings() {
            let lines = rendering.split(separator: "\n", omittingEmptySubsequences: false)
            #expect(lines.allSatisfy { $0.hasPrefix(VerificationReport.managedBlockPrefix) })
        }
    }

    @Test("A dropped clause keeps its citation and dropped reason on rung 2, and its reason on rung 3 (OQ157)")
    func droppedClause() {
        let dropped = ClauseVerificationRecord(
            issueID: "FEAT-1", cid: "c9", level: "feature", text: "Clause text of c9", locationID: "epic/story",
            citationProvenance: "machine-found", verdict: nil, droppedReason: "asserts landing's own output",
            whatWasChecked: "", interpretation: "", judgedBy: .agent, invalidatedCause: nil
        )
        let renderings = VerificationReport(clauses: [dropped, clause("BACK-1", "c1")]).managedBlockRenderings()
        #expect(renderings[1].contains(
            "Verification: FEAT-1 c9 · Clause text of c9 · Spec Citation (epic/story) · [machine-found] · "
                + "dropped: asserts landing's own output\n"
        ))
        #expect(renderings[2].contains("Verification: FEAT-1 c9 · dropped: asserts landing's own output\n"))
    }
}
