import Domain
@testable import Engine
import Foundation
@testable import Journal
import Testing

// roadmap P10.5 (verification/verify-a-feature-clause-by-clause): the clause-by-clause report and the two
// places it is written. Rendering only — the verdicts in these fixtures are fixed by hand.

private func clause(
    _ issue: String = "BACK-1", _ cid: String = "c1", text: String = "Returns 404 for a missing id.",
    location: String = "epic/story", provenance: String = "machine-found", verdict: ClauseVerdict = .met,
    judgedBy: ClauseJudge = .agent, invalidatedCause: String? = nil
) -> ClauseVerificationRecord {
    ClauseVerificationRecord(
        issueID: issue, cid: cid, level: issue == "FEAT-1" ? "feature" : "card", text: text, locationID: location,
        citationProvenance: provenance, verdict: verdict, whatWasChecked: "read the handler",
        interpretation: "the id is the path parameter", judgedBy: judgedBy, invalidatedCause: invalidatedCause
    )
}

private let mixedReport = VerificationReport(clauses: [
    clause("FEAT-1", "c1", provenance: "Author-supplied"),
    clause("BACK-1", "c1", verdict: .unmet),
    clause("BACK-1", "c2", location: "gone/story", verdict: .unresolved, judgedBy: .engine)
])

@Suite("Verification report rendering (P10.5)")
struct VerificationReportTests {
    @Test("A clause line is the story's fields in order, separated by ·, whatever the verdict")
    func lineShape() {
        #expect(
            VerificationReport.line(for: clause())
                == "BACK-1 c1 · Returns 404 for a missing id. · Spec Citation (epic/story) · [machine-found] · met "
                + "· read the handler · the id is the path parameter"
        )
        #expect(VerificationReport.line(for: clause(verdict: .unmet)).contains(" · [machine-found] · unmet · "))
        let unresolved = VerificationReport.line(for: clause(verdict: .unresolved))
        #expect(unresolved.contains(" · [machine-found] · unresolved · "))
        let authored = VerificationReport.line(for: clause(provenance: "Author-supplied"))
        #expect(authored.contains(" · [Author-supplied] · met · "))
    }

    @Test("A field with newlines never breaks the one-line-per-clause shape")
    func newlinesCollapse() {
        let line = VerificationReport.line(for: clause(text: "First line.\nSecond line."))
        #expect(!line.contains("\n"))
        #expect(line.contains("First line. Second line."))
    }

    @Test("The Managed Block variant starts every line with the prefix, and carries the limitation")
    func managedBlockLines() {
        let lines = mixedReport.managedBlockLines().split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 1 + 3 + 1)
        #expect(lines.allSatisfy { $0.hasPrefix(VerificationReport.managedBlockPrefix) })
        #expect(lines.last?.contains("auditable, not sound") == true)
        #expect(lines.last?.contains("wrong or thin") == true)
        #expect(lines.last?.contains("incoherent as a whole") == true)
        #expect(lines.last?.contains("which Feature was selected") == true)
    }

    @Test("No surface reports an aggregate pass, verification or failure")
    func noAggregate() {
        let all = [mixedReport.managedBlockLines(), mixedReport.markdownSection()]
        let clean = VerificationReport(clauses: [clause(), clause("BACK-1", "c2")])
        for text in all + [clean.managedBlockLines(), clean.markdownSection()] {
            let lowered = text.lowercased()
            #expect(!lowered.contains("passed"))
            #expect(!lowered.contains("all clauses met"))
            #expect(!lowered.contains("verified:"))
            #expect(!lowered.contains("failed"))
        }
    }

    @Test("The Markdown variant is a section: one bullet per clause, the limitation beneath")
    func markdownSection() {
        let lines = mixedReport.markdownSection().split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.first == "## Verification, clause by clause")
        #expect(lines.filter { $0.hasPrefix("- ") }.count == 3)
        #expect(lines.last?.hasPrefix("Known limitation:") == true)
    }

    @Test("unmetOrUnresolved is every clause the report did not find met")
    func unmetOrUnresolved() {
        #expect(mixedReport.unmetOrUnresolved.map(\.cid) == ["c1", "c2"])
        #expect(mixedReport.unmetOrUnresolved.map(\.verdict) == [.unmet, .unresolved])
    }
}

// MARK: - Pull request body

private func bodyInput(
    cards: [PullRequestBodyCard], unmet: [PullRequestBodyUnmetClause] = [], report: VerificationReport? = nil
) -> PullRequestBodyInput {
    PullRequestBodyInput(
        featureTitle: "Widgets", featureIssueURL: nil, nightID: 3, nightTimestamp: "2026-09-16",
        repository: "backend", pushedRepositoryCount: 1, mergedCount: 0, cycleCards: cards,
        mergeVerdict: PullRequestBodyMergeVerdict(conflict: false, untestable: true), unmetClauses: unmet,
        verificationReport: report
    )
}

private let doneCard = PullRequestBodyCard(
    title: "BACK-1", repository: "backend", state: .done, routeSummary: "r", checkSummary: "c", roundCount: 1
)
private let blockedCard = PullRequestBodyCard(
    title: "BACK-2", repository: "backend", state: .blocked, routeSummary: "r", checkSummary: "c", roundCount: 1,
    blockReason: "route failure"
)

@Suite("Pull request body carries the Verification report (P10.5)")
struct VerificationPullRequestBodyTests {
    @Test("With a report the body includes the section and its limitation")
    func includesReport() {
        let body = PullRequestBody.render(bodyInput(cards: [doneCard], report: mixedReport))
        #expect(body.contains("## Verification, clause by clause"))
        #expect(body.contains("BACK-1 c2 · Returns 404 for a missing id. · Spec Citation (gone/story)"))
        #expect(body.contains("Known limitation: this makes the check auditable, not sound."))
    }

    @Test("A Partial Landing lists unmet clauses derived from the report, so the two cannot disagree")
    func unmetListComesFromTheReport() {
        // The caller's own list names a clause the report does not; the report wins.
        let stale = [PullRequestBodyUnmetClause(workCardTitle: "BACK-9", text: "Stale clause.", citation: "x/y")]
        let body = PullRequestBody.render(bodyInput(cards: [doneCard, blockedCard], unmet: stale, report: mixedReport))
        #expect(body.contains("Definition of Done clauses unmet:"))
        #expect(body.contains("- BACK-1: \"Returns 404 for a missing id.\" (epic/story) — unmet"))
        #expect(body.contains("- BACK-1: \"Returns 404 for a missing id.\" (gone/story) — unmet"))
        #expect(!body.contains("Stale clause."))
        #expect(body.contains("2 Definition of Done clauses remain unmet"))
    }

    @Test("Without a report the body is exactly what it was")
    func unchangedWithoutReport() {
        let unmet = [PullRequestBodyUnmetClause(workCardTitle: "BACK-2", text: "A clause.", citation: "x/y")]
        let body = PullRequestBody.render(bodyInput(cards: [doneCard, blockedCard], unmet: unmet))
        #expect(!body.contains("Verification, clause by clause"))
        #expect(!body.contains("Known limitation"))
        #expect(body.contains("- BACK-2: \"A clause.\" (x/y) — unmet"))
        #expect(body.contains("1 Definition of Done clauses remain unmet"))
    }
}
