import Domain
@testable import Engine
import Testing

// spec ruling OQ182 (2026-10-22), item 4: the Partial Landing pull request body names each held Work
// Card by the Work Card it waits on, counts it among the carried-forward Work Cards, and a lane whose
// only unfinished Work Card is held still renders as a Partial Landing, never as a complete one.
// Rendered strings only; nothing about GitHub.

@Suite("Pull request body: held Work Cards (OQ182 item 4)")
struct PullRequestBodyHeldTests {
    private static let doneCard = PullRequestBodyCard(
        title: "BACK-1", repository: "backend", state: .done, routeSummary: "r", checkSummary: "c", roundCount: 1
    )
    private static let heldCard = PullRequestBodyCard(
        title: "BACK-2", repository: "backend", state: .todo, routeSummary: "", checkSummary: "", roundCount: 0,
        heldBehindTitle: "BACK-1 redux"
    )

    private static func input(_ cards: [PullRequestBodyCard]) -> PullRequestBodyInput {
        PullRequestBodyInput(
            featureTitle: "Widgets", featureIssueURL: nil, nightID: 3, nightTimestamp: "2026-10-23",
            repository: "backend", pushedRepositoryCount: 1, mergedCount: 0, cycleCards: cards,
            mergeVerdict: PullRequestBodyMergeVerdict(conflict: false, untestable: true), unmetClauses: []
        )
    }

    @Test("A held Card renders a Partial Landing, never a complete one, even with no other incomplete Card")
    func heldAloneForcesPartialLanding() {
        let body = PullRequestBody.render(Self.input([Self.doneCard, Self.heldCard]))
        #expect(body.hasPrefix("**partial · "))
        // Neither Blocked nor Waiting on You: the fixed line 1 wording is still true at "0 blocked"
        // (spec ruling OQ182 item 4: a held Card's own state is Todo).
        #expect(body.contains("0 blocked"))
    }

    @Test("The incomplete-Cards section lists a held Card as Todo, held behind its holder's title")
    func incompleteSectionNamesTheHolder() {
        let body = PullRequestBody.render(Self.input([Self.doneCard, Self.heldCard]))
        #expect(body.contains("- BACK-2 [backend]: Todo — held behind \"BACK-1 redux\""))
    }

    @Test("The carried-forward section names a held Card by title and repository, held behind its holder")
    func carriedForwardSectionNamesTheHolder() {
        let body = PullRequestBody.render(Self.input([Self.doneCard, Self.heldCard]))
        #expect(body.contains("- BACK-2 [backend] — held behind \"BACK-1 redux\""))
    }

    @Test("Line 2's carried-forward count includes held Cards")
    func lineTwoCountsHeldCards() {
        let body = PullRequestBody.render(Self.input([Self.doneCard, Self.heldCard]))
        #expect(body.contains("1 unfinished Cards are carried forward"))
    }

    @Test("A held Card behind a Blocked hole: both are named, and the carried-forward count is 2")
    func heldCardBehindABlockedHole() {
        let blockedHolder = PullRequestBodyCard(
            title: "BACK-1", repository: "backend", state: .blocked, routeSummary: "r", checkSummary: "c",
            roundCount: 1, blockReason: "route failure"
        )
        let held = PullRequestBodyCard(
            title: "BACK-2", repository: "backend", state: .todo, routeSummary: "", checkSummary: "", roundCount: 0,
            heldBehindTitle: "BACK-1"
        )
        let body = PullRequestBody.render(Self.input([blockedHolder, held]))
        #expect(body.contains("- BACK-1 [backend]: Blocked — route failure"))
        #expect(body.contains("- BACK-2 [backend]: Todo — held behind \"BACK-1\""))
        #expect(body.contains("2 unfinished Cards are carried forward"))
    }

    @Test("A Card that is Waiting on You and a held Card both appear in the carried-forward section")
    func waitingOnYouAndHeldBothCarryForward() {
        let waiting = PullRequestBodyCard(
            title: "MOB-1", repository: "mobile", state: .waitingOnYou, routeSummary: "r", checkSummary: "c",
            roundCount: 1, waitingReason: .question
        )
        let body = PullRequestBody.render(Self.input([Self.doneCard, Self.heldCard, waiting]))
        #expect(body.contains("- BACK-2 [backend] — held behind \"BACK-1 redux\""))
        #expect(body.contains("- MOB-1 [mobile]"))
        #expect(body.contains("2 unfinished Cards are carried forward"))
    }
}
