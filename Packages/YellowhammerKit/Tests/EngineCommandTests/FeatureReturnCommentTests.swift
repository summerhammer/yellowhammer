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

    private struct DuplicateClausesFixture {
        let feature: FeatureRecord
        let card: CardRecord
        let clauses: [ClauseVerificationRecord]
    }

    private func makeDuplicateClausesFixture() -> DuplicateClausesFixture {
        let featureUUID = "201acaaa-c2ce-4082-a90a-096a50228fa7"
        let cardUUID = "ac155696-c2ce-4082-a90a-096a50228fa7"
        let feature = FeatureRecord(
            id: 1, issueID: featureUUID, issueIDForDisplay: "YLH-325", state: "returned",
            worktreeName: nil, createdAt: Date(), abandonedAt: nil, closedBy: nil,
            issueKey: "YLH-325", issueURL: "https://linear.app/team/issue/YLH-325"
        )
        let card = CardRecord(
            id: 2, cycleID: 1, issueID: cardUUID, issueIDForDisplay: "YLH-326", title: "Card 1 title",
            repository: "backend", kind: "card", authoredOrder: 1, state: .done, waitingReason: nil,
            blockReason: nil, shelvedFromState: nil, budgetEpoch: 0, createdAt: Date(), stateVersion: 1,
            boardStateVersion: 1, unansweredNights: 0, unansweredLastCountedNightID: nil, failedAdoptions: 0,
            divergenceStandingNightID: nil, issueKey: "YLH-326", issueURL: "https://linear.app/team/issue/YLH-326"
        )
        let clauses = [
            ClauseVerificationRecord(
                issueID: featureUUID, cid: "c1", level: "feature", text: "Clause c1 text.",
                locationID: "epic/story", citationProvenance: "machine-found", verdict: .met,
                whatWasChecked: "checked c1", interpretation: "read c1", judgedBy: .agent
            ),
            ClauseVerificationRecord(
                issueID: featureUUID, cid: "c2", level: "feature", text: "Clause c2 text.",
                locationID: "epic/story", citationProvenance: "machine-found", verdict: .unmet,
                whatWasChecked: "checked c2", interpretation: "read c2", judgedBy: .engine
            ),
            ClauseVerificationRecord(
                issueID: cardUUID, cid: "c1", level: "card", text: "Clause c1 text.",
                locationID: "epic/story", citationProvenance: "machine-found", verdict: .met,
                whatWasChecked: "checked c1", interpretation: "read c1", judgedBy: .agent
            ),
            ClauseVerificationRecord(
                issueID: cardUUID, cid: "c2", level: "card", text: "Clause c2 text.",
                locationID: "epic/story", citationProvenance: "machine-found", verdict: .unmet,
                whatWasChecked: "checked c2", interpretation: "read c2", judgedBy: .engine
            )
        ]
        return DuplicateClausesFixture(feature: feature, card: card, clauses: clauses)
    }

    @Test("Output contains no UUID when identifiers are recorded, and lists each clause exactly once")
    func containsNoUUIDAndListsEachClauseOnce() throws {
        let fixture = makeDuplicateClausesFixture()
        let record = FeatureVerificationRecord(
            id: 1, featureID: 1, cycleID: 1, route: nil, nightID: 1, runID: RunID(),
            verifiedAt: Date(), clauses: fixture.clauses
        )
        let comment = FeatureReturnComment(
            record: record, pullRequests: [:], feature: fixture.feature, cards: [fixture.card]
        )
        let body = comment.body()

        let uuidRegex = try Regex(#"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#)
        #expect(!body.contains(uuidRegex))

        let c1Count = body.components(separatedBy: "Clause c1 text.").count - 1
        let c2Count = body.components(separatedBy: "Clause c2 text.").count - 1
        #expect(c1Count == 1)
        #expect(c2Count == 1)

        #expect(body.contains("Feature [YLH-325](https://linear.app/team/issue/YLH-325) c1"))
        #expect(body.contains("Feature [YLH-325](https://linear.app/team/issue/YLH-325) c2"))
    }

    @Test("Falls back to Card title when identifier is unknown")
    func fallsBackToCardTitle() throws {
        let cardUUID = "bc155696-c2ce-4082-a90a-096a50228fa7"
        let card = CardRecord(
            id: 3, cycleID: 1, issueID: cardUUID, issueIDForDisplay: nil, title: "Parse YAML",
            repository: "backend", kind: "card", authoredOrder: 1, state: .done, waitingReason: nil,
            blockReason: nil, shelvedFromState: nil, budgetEpoch: 0, createdAt: Date(), stateVersion: 1,
            boardStateVersion: 1, unansweredNights: 0, unansweredLastCountedNightID: nil, failedAdoptions: 0,
            divergenceStandingNightID: nil, issueKey: nil, issueURL: "https://linear.app/team/issue/YAML-1"
        )
        let clauses = [
            ClauseVerificationRecord(
                issueID: cardUUID, cid: "c1", level: "card", text: "Parse yaml file.",
                locationID: "epic/story", citationProvenance: "machine-found", verdict: .unmet,
                whatWasChecked: "checked c1", interpretation: "read c1", judgedBy: .engine
            )
        ]
        let comment = FeatureReturnComment(
            clauses: clauses,
            pullRequests: [:],
            issues: [cardUUID: FeatureReturnComment.IssueDisplay(card: card)]
        )
        let body = comment.body()

        let uuidRegex = try Regex(#"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#)
        #expect(!body.contains(uuidRegex))
        #expect(body.contains("Work Card [Parse YAML](https://linear.app/team/issue/YAML-1) c1"))
    }
}
