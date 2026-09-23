import Domain
@testable import Engine
import Foundation
@testable import Journal
import Testing

// roadmap P10.6: the return comment's pure rendering, against fixture clause records. Never asserts
// model-authored content — only the wiring and vocabulary the story mandates.

private func clause(_ cid: String, issue: String = "BACK-1", verdict: ClauseVerdict) -> ClauseVerificationRecord {
    ClauseVerificationRecord(
        issueID: issue, cid: cid, level: "card", text: "Clause \(cid).", locationID: "epic/story",
        citationProvenance: "machine-found", verdict: verdict, whatWasChecked: "checked \(cid)",
        interpretation: "read \(cid)", judgedBy: verdict == .met ? .agent : .engine
    )
}

private func pullRequest(repository: String, url: String?) -> PullRequestRecord {
    PullRequestRecord(featureID: 1, repository: repository, url: url, nightID: 1, runID: RunID(), openedAt: Date())
}

@Suite("Feature return comment (P10.6)")
struct FeatureReturnCommentTests {
    @Test("Unmet, unresolved and met clauses each render in their own section, no aggregate headline")
    func rendersEveryClauseSection() {
        let comment = FeatureReturnComment(
            clauses: [
                clause("c1", verdict: .unmet),
                clause("c2", verdict: .unresolved),
                clause("c3", verdict: .met)
            ],
            pullRequests: [:]
        )
        let body = comment.body()

        #expect(body.contains("returned to the Operator"))
        #expect(body.contains("not Done"))
        #expect(body.contains("Cycle is not archived"))
        #expect(body.contains("## Unmet clauses"))
        #expect(body.contains("BACK-1 c1"))
        #expect(body.contains("## Unresolved clauses"))
        #expect(body.contains("Specification Author"))
        #expect(body.contains("BACK-1 c2"))
        #expect(body.contains("not unfinished work"))
        #expect(body.contains("## Met clauses"))
        #expect(body.contains("BACK-1 c3"))
        #expect(body.contains("auditable, not sound"))
        #expect(!body.lowercased().contains("passed"))
        #expect(!body.contains("2 unmet"))
    }

    @Test("An empty section is omitted: no unresolved clauses means no unresolved heading")
    func omitsEmptySections() {
        let comment = FeatureReturnComment(clauses: [clause("c1", verdict: .unmet)], pullRequests: [:])
        let body = comment.body()

        #expect(!body.contains("Unresolved clauses"))
        #expect(!body.contains("Met clauses"))
    }

    @Test("Pull requests already opened are listed as still open, by repository")
    func listsPullRequestsStillOpen() {
        let comment = FeatureReturnComment(
            clauses: [clause("c1", verdict: .unmet)],
            pullRequests: [
                "backend": pullRequest(repository: "backend", url: "https://github.com/summerhammer/backend/pull/1"),
                "mobile": pullRequest(repository: "mobile", url: nil)
            ]
        )
        let body = comment.body()

        #expect(body.contains("backend"))
        #expect(body.contains("https://github.com/summerhammer/backend/pull/1"))
        #expect(body.contains("still open"))
        #expect(body.contains("mobile"))
    }

    @Test("With no pull request recorded, the section says none was opened")
    func statesNoneOpenedWhenEmpty() {
        let comment = FeatureReturnComment(clauses: [clause("c1", verdict: .unmet)], pullRequests: [:])
        #expect(comment.body().contains("none was opened"))
    }
}
