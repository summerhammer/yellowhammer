import Domain
@testable import Engine
import Foundation
@testable import Journal
import Testing

// verification/verify-a-feature-clause-by-clause and verification/return-a-feature-with-unmet-clauses: the
// comment that reports a check that never ran says why when the Repo declared `check = none`.

@Suite("Not checked: return and merge-closure comments attribute a declared check = none")
struct NotCheckedAttributionTests {
    private func notChecked() -> ClauseVerificationRecord {
        ClauseVerificationRecord(
            issueID: "BACK-1", cid: "c1", level: "feature", text: "xcodebuild test passes.",
            locationID: "epic/story", citationProvenance: "machine-found", verdict: .notChecked,
            whatWasChecked: "ran the command; exited 74", interpretation: "as written", judgedBy: .agent
        )
    }

    @Test("The return comment's heading names the repository that declared check = none")
    func returnCommentHeadingNamesRepository() {
        let body = FeatureReturnComment(
            clauses: [notChecked()], pullRequests: [:], noCheckRepositories: ["seshes-darwin"]
        ).body()
        #expect(body.contains(
            "## Not checked clauses (checks that never ran, not unfinished work; "
                + "no automated Check configured: `seshes-darwin` declares `check = none`)"
        ))
    }

    @Test("The return comment keeps its plain heading when no repository declared none")
    func returnCommentHeadingIsPlainOtherwise() {
        let body = FeatureReturnComment(clauses: [notChecked()], pullRequests: [:]).body()
        #expect(body.contains("## Not checked clauses (checks that never ran, not unfinished work)"))
        #expect(!body.contains("declares `check = none`"))
    }

    @Test("The merge-closure comment attributes a not checked clause the same way")
    func mergeClosureHeadingNamesRepository() throws {
        let night = try #require(NightStart(rawValue: "2026-10-19"))
        let attributed = FeatureMergeClosureComment(
            landings: ["seshes-darwin": "abc"], carriedForward: [], acceptedCards: [], unmetClauses: [],
            notCheckedClauses: [notChecked()], noCheckRepositories: ["seshes-darwin"],
            triagedNightStart: night, observingNightStart: night
        ).body()
        #expect(attributed.contains(
            "## Not checked (checks that never ran; no automated Check configured: "
                + "`seshes-darwin` declares `check = none`)"
        ))
        let plain = FeatureMergeClosureComment(
            landings: ["seshes-darwin": "abc"], carriedForward: [], acceptedCards: [], unmetClauses: [],
            notCheckedClauses: [notChecked()], triagedNightStart: night, observingNightStart: night
        ).body()
        #expect(plain.contains("## Not checked (checks that never ran)"))
    }
}
