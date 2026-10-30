import Domain
@testable import Engine
import Testing

// roadmap P23.4 (spec: landing/open-one-pull-request-per-repository `#stack-notice`; sponsor ruling 2026-10-21
// Q3; agent rulings 2026-10-21 items 4 and 12, pending sponsor review): where the stack notice sits in a
// rendered pull request body, and its wording. Rendered strings only; nothing about GitHub.

@Suite("Pull request body: the stack notice (P23.4)")
struct PullRequestBodyStackNoticeTests {
    private static let notice = PullRequestStackNotice(
        predecessorPullRequestNumber: 7, predecessorBranch: "b1", predecessorFeature: "YLH-1", defaultBranch: "main"
    )

    private static let doneCard = PullRequestBodyCard(
        title: "BACK-1", repository: "backend", state: .done, routeSummary: "r", checkSummary: "c", roundCount: 1
    )
    private static let blockedCard = PullRequestBodyCard(
        title: "BACK-2", repository: "backend", state: .blocked, routeSummary: "r", checkSummary: "c",
        roundCount: 1, blockReason: "route failure"
    )

    private static let opening = "**verified · 1 of 1 Cards landed · 0 of 1 merged**"

    private static func body(_ cards: [PullRequestBodyCard], notice: PullRequestStackNotice? = nil) -> String {
        PullRequestBody.render(PullRequestBodyInput(
            featureTitle: "Widgets", featureIssueURL: "https://linear.app/x/issue/YLH-2", nightID: 3,
            nightTimestamp: "2026-10-21", repository: "backend", pushedRepositoryCount: 1, mergedCount: 0,
            cycleCards: cards, mergeVerdict: PullRequestBodyMergeVerdict(conflict: false, untestable: true),
            unmetClauses: [], stackNotice: notice, rollUpOpening: opening
        ))
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    @Test("The notice reads word for word as the story's, with the placeholders filled")
    func noticeWording() {
        #expect(Self.notice.rendered == """
            Stacked on #7 (`b1`) from Feature YLH-1. Merge #7 first. Merging this one first merges it into `b1`, \
            not `main`: it reaches mainline when #7 merges, and both then count. If #7 has merged and this pull \
            request still targets `b1`, change its base to `main` before merging.
            """)
    }

    @Test("Without a recorded predecessor pull request the notice names it in words, never as #<n>")
    func noticeWithoutPredecessorNumber() {
        let notice = PullRequestStackNotice(
            predecessorPullRequestNumber: nil, predecessorBranch: "b1", predecessorFeature: "YLH-1",
            defaultBranch: "main"
        )
        #expect(notice.rendered.hasPrefix("Stacked on the predecessor's pull request (`b1`) from Feature YLH-1. "))
        #expect(notice.rendered.contains("Merge the predecessor's pull request first."))
        #expect(!notice.rendered.contains("#"))
    }

    @Test("The predecessor's number is read from the end of its recorded pull request URL")
    func numberFromURL() {
        #expect(PullRequestStackNotice.pullRequestNumber(fromURL: "https://github.com/o/r/pull/42") == 42)
        #expect(PullRequestStackNotice.pullRequestNumber(fromURL: "https://github.com/o/r/pull/42/") == 42)
        #expect(PullRequestStackNotice.pullRequestNumber(fromURL: "https://github.com/o/r/issues/42") == nil)
        #expect(PullRequestStackNotice.pullRequestNumber(fromURL: nil) == nil)
    }

    @Test("A complete stacked body opens with the Roll-up sentence, the notice directly after it")
    func completeBodyRollUpThenNotice() {
        let plain = Self.body([Self.doneCard]).components(separatedBy: "\n")
        let stacked = Self.body([Self.doneCard], notice: Self.notice).components(separatedBy: "\n")
        #expect(plain[0] == Self.opening)
        #expect(plain[1].isEmpty)
        #expect(plain[2].hasPrefix("Feature: "))
        #expect(stacked[0] == Self.opening)
        #expect(stacked[1].isEmpty)
        #expect(stacked[2] == Self.notice.rendered)
        #expect(stacked[3].isEmpty)
        #expect(Array(stacked.dropFirst(4)) == Array(plain.dropFirst(2)))
        #expect(!plain.joined(separator: "\n").contains("Stacked on"))
        #expect(!stacked.contains { $0.hasPrefix("*As of Night") })
    }

    @Test("A Partial Landing keeps Lines 1-2 and the As-of stamp word for word, and the notice follows the stamp")
    func partialBodyNoticeAfterStamp() {
        let plain = Self.body([Self.doneCard, Self.blockedCard]).components(separatedBy: "\n")
        let stacked = Self.body([Self.doneCard, Self.blockedCard], notice: Self.notice).components(separatedBy: "\n")
        #expect(Array(stacked.prefix(3)) == Array(plain.prefix(3)))
        #expect(stacked[0].hasPrefix("**partial · "))
        #expect(stacked[2].hasPrefix("*As of Night 3 (2026-10-21)."))
        #expect(stacked[3] == Self.notice.rendered)
        #expect(Array(stacked.dropFirst(4)) == Array(plain.dropFirst(3)))
    }

    @Test("The release sentence leads with the any-method sentence, exactly once, and recommends no method (#716)")
    func releaseSentenceOnce() {
        let shared = "Merging the pull request by any method releases the next Feature."
        for cards in [[Self.doneCard], [Self.doneCard, Self.blockedCard]] {
            for notice in [nil, Self.notice] {
                let body = Self.body(cards, notice: notice)
                #expect(Self.occurrences(of: shared, in: body) == 1)
                #expect(!body.contains("Create a merge commit"))
                #expect(!body.contains("git merge -s ours"))
            }
        }
        let complete = Self.body([Self.doneCard], notice: Self.notice)
        #expect(complete.contains(
            "\n" + shared + " It clears this Feature's slot in the unmerged Feature stack (`unmerged_features_max`) "
                + "and releases any downstream Features waiting on it. Leaving it open costs tomorrow night.\n"
        ))
        let partial = Self.body([Self.doneCard, Self.blockedCard], notice: Self.notice)
        #expect(partial.contains(
            "\n" + shared + " It satisfies the landing gate for the repositories it reached, clears this Feature's "
                + "slot in the unmerged Feature stack (`unmerged_features_max`) and releases any downstream "
                + "Features waiting on it. Leaving it open costs tomorrow night.\n"
        ))
    }
}
