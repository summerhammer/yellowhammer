import Domain
@testable import Engine
import Journal
import Testing

// The Roll-up lattice (roadmap P12.3; glossary → Roll-up; spec: board-projection/maintain-the-managed-
// block, second story): pure value + sentence rendering, no Journal access.

@Suite("Feature Roll-up (P12.3)")
struct FeatureRollUpTests {
    private func member(
        _ issueID: String, repo: String = "backend", order: Int = 0, state: CardState,
        waitingReason: WaitingReason? = nil, blockReason: String? = nil
    ) -> RollUpMember {
        RollUpMember(issueID: issueID, repository: repo, authoredOrder: order, state: state,
                     waitingReason: waitingReason, blockReason: blockReason)
    }

    private func noMerge() -> MergedFraction { MergedFraction(mergedCount: 0, totalCount: 0) }

    // MARK: - Every lattice word reachable

    @Test("Waiting on You dominates the running half: needs you")
    func needsYouReached() {
        let rollUp = FeatureRollUp(
            members: [member("A", state: .waitingOnYou), member("B", state: .done)],
            lanesPushed: false, verificationPassed: false, mergedFraction: noMerge(), issueStanding: .authoring
        )
        #expect(rollUp.state == .needsYou)
        #expect(rollUp.sentence == "needs you · 1 of 2 Cards landed · 1 waiting on you")
    }

    @Test("Blocked dominates when nothing is Waiting on You: blocked")
    func blockedReached() {
        let rollUp = FeatureRollUp(
            members: [member("A", state: .blocked), member("B", state: .done)],
            lanesPushed: false, verificationPassed: false, mergedFraction: noMerge(), issueStanding: .authoring
        )
        #expect(rollUp.state == .blocked)
        #expect(rollUp.sentence == "blocked · 1 of 2 Cards landed · 1 blocked")
    }

    @Test("An In Progress Card with nothing worse: running, with the In Progress count on top")
    func runningWithInProgress() {
        let rollUp = FeatureRollUp(
            members: [member("A", state: .inProgress), member("B", state: .done)],
            lanesPushed: false, verificationPassed: false, mergedFraction: noMerge(), issueStanding: .authoring
        )
        #expect(rollUp.state == .running)
        #expect(rollUp.sentence == "running · 1 of 2 Cards landed · 1 running")
    }

    @Test("Only Todo/Done left: running, and the top slot is 'all on track'")
    func runningAllOnTrack() {
        let rollUp = FeatureRollUp(
            members: [member("A", state: .todo), member("B", state: .done)],
            lanesPushed: false, verificationPassed: false, mergedFraction: noMerge(), issueStanding: .authoring
        )
        #expect(rollUp.state == .running)
        #expect(rollUp.sentence == "running · 1 of 2 Cards landed · all on track")
    }

    @Test("Closed half, Waiting on You: partial landing")
    func partialLandingWaitingOnYou() {
        let rollUp = FeatureRollUp(
            members: [member("A", state: .waitingOnYou), member("B", state: .done)],
            lanesPushed: true, verificationPassed: false,
            mergedFraction: MergedFraction(mergedCount: 2, totalCount: 2), issueStanding: .authoring
        )
        #expect(rollUp.state == .partialLanding)
        #expect(rollUp.sentence == "partial landing · 1 of 2 Cards landed · 1 waiting on you")
    }

    @Test("Closed half, Blocked (no Waiting on You): partial landing")
    func partialLandingBlocked() {
        let rollUp = FeatureRollUp(
            members: [member("A", state: .blocked), member("B", state: .done)],
            lanesPushed: true, verificationPassed: false,
            mergedFraction: MergedFraction(mergedCount: 2, totalCount: 2), issueStanding: .authoring
        )
        #expect(rollUp.state == .partialLanding)
        #expect(rollUp.sentence == "partial landing · 1 of 2 Cards landed · 1 blocked")
    }

    @Test("All Done and Verification passed: verified, with 'all verified' on top")
    func verifiedReached() {
        let rollUp = FeatureRollUp(
            members: [member("A", state: .done), member("B", state: .done)],
            lanesPushed: true, verificationPassed: true,
            mergedFraction: MergedFraction(mergedCount: 2, totalCount: 2), issueStanding: .authoring
        )
        #expect(rollUp.state == .verified)
        #expect(rollUp.sentence == "verified · 2 of 2 Cards landed · all verified")
    }

    @Test("Spec gap: all Done but Verification not passed renders partial landing")
    func specGapAllDoneVerificationNotPassed() {
        let rollUp = FeatureRollUp(
            members: [member("A", state: .done), member("B", state: .done)],
            lanesPushed: true, verificationPassed: false,
            mergedFraction: MergedFraction(mergedCount: 2, totalCount: 2), issueStanding: .authoring
        )
        #expect(rollUp.state == .partialLanding)
        #expect(rollUp.sentence == "partial landing · 2 of 2 Cards landed · verification not passed")
    }

    // MARK: - Zero-Card templates

    @Test("Zero Cards, authoring standing")
    func zeroCardAuthoring() {
        let rollUp = FeatureRollUp(
            members: [], lanesPushed: false, verificationPassed: false, mergedFraction: noMerge(),
            issueStanding: .authoring
        )
        #expect(rollUp.state == .authoring)
        #expect(rollUp.sentence == "authoring · no Cards yet · in authoring")
    }

    @Test("Zero Cards, Refusal open")
    func zeroCardRefusalOpen() {
        let rollUp = FeatureRollUp(
            members: [], lanesPushed: false, verificationPassed: false, mergedFraction: noMerge(),
            issueStanding: .awaitingYou(.refusal)
        )
        #expect(rollUp.state == .needsYou)
        #expect(rollUp.sentence == "needs you · no Cards yet · refusal awaiting you")
    }

    @Test("Zero Cards, Refusal expired")
    func zeroCardRefusalExpired() {
        let rollUp = FeatureRollUp(
            members: [], lanesPushed: false, verificationPassed: false, mergedFraction: noMerge(),
            issueStanding: .unanswered(.refusal)
        )
        #expect(rollUp.state == .blocked)
        #expect(rollUp.sentence == "blocked · no Cards yet · refusal unanswered")
    }

    @Test("Zero Cards, Authoring Halt open")
    func zeroCardHaltOpen() {
        let rollUp = FeatureRollUp(
            members: [], lanesPushed: false, verificationPassed: false, mergedFraction: noMerge(),
            issueStanding: .awaitingYou(.halt)
        )
        #expect(rollUp.state == .needsYou)
        #expect(rollUp.sentence == "needs you · no Cards yet · halt awaiting you")
        #expect(!rollUp.sentence.contains("refusal"))
    }

    @Test("Zero Cards, Authoring Halt expired")
    func zeroCardHaltExpired() {
        let rollUp = FeatureRollUp(
            members: [], lanesPushed: false, verificationPassed: false, mergedFraction: noMerge(),
            issueStanding: .unanswered(.halt)
        )
        #expect(rollUp.state == .blocked)
        #expect(rollUp.sentence == "blocked · no Cards yet · halt unanswered")
        #expect(!rollUp.sentence.contains("refusal"))
    }

    @Test("A zero-Card Feature never renders verified, even with lanes pushed and Verification passed")
    func zeroCardNeverVerified() {
        let rollUp = FeatureRollUp(
            members: [], lanesPushed: true, verificationPassed: true,
            mergedFraction: MergedFraction(mergedCount: 3, totalCount: 3), issueStanding: .authoring
        )
        #expect(rollUp.state != .verified)
        #expect(rollUp.state == .authoring)
    }

    // MARK: - Absent

    @Test("Every member Card Cancelled: absent, even under an awaiting-you zero-Card standing")
    func absentWhenAllCancelled() {
        let rollUp = FeatureRollUp(
            members: [
                member("A", order: 0, state: .cancelled), member("B", order: 1, state: .cancelled),
                member("C", order: 2, state: .cancelled)
            ],
            lanesPushed: false, verificationPassed: false, mergedFraction: noMerge(),
            issueStanding: .awaitingYou(.refusal)
        )
        #expect(rollUp.state == nil)
        #expect(rollUp.sentence == "no live Cards · 3 cancelled")
    }

    // MARK: - Cancelled excluded from the denominator

    @Test("Cancelled Cards are excluded from k and N")
    func cancelledExcludedFromDenominator() {
        let rollUp = FeatureRollUp(
            members: [
                member("A", order: 0, state: .done), member("B", order: 1, state: .done),
                member("C", order: 2, state: .done), member("D", order: 3, state: .cancelled)
            ],
            lanesPushed: false, verificationPassed: false, mergedFraction: noMerge(), issueStanding: .authoring
        )
        #expect(rollUp.sentence.contains("3 of 3 Cards landed"))
    }

    // MARK: - Single Blocked dominates and is counted

    @Test("Single Blocked dominates and is counted in the running half")
    func singleBlockedDominates() {
        let rollUp = FeatureRollUp(
            members: [
                member("A", order: 0, state: .blocked), member("B", order: 1, state: .done),
                member("C", order: 2, state: .done), member("D", order: 3, state: .done),
                member("E", order: 4, state: .inProgress)
            ],
            lanesPushed: false, verificationPassed: false, mergedFraction: noMerge(), issueStanding: .authoring
        )
        #expect(rollUp.state == .blocked)
        #expect(rollUp.sentence == "blocked · 3 of 5 Cards landed · 1 blocked")
    }

    // MARK: - Merged fraction

    @Test("Closed half renders the merged fraction slot when not fully merged")
    func mergedFractionSlotZeroOfTwo() {
        let rollUp = FeatureRollUp(
            members: [member("A", state: .waitingOnYou)], lanesPushed: true, verificationPassed: false,
            mergedFraction: MergedFraction(mergedCount: 0, totalCount: 2), issueStanding: .authoring
        )
        #expect(rollUp.sentence.contains("0 of 2 merged"))
    }

    @Test("Closed half renders the merged fraction slot mid-way")
    func mergedFractionSlotOneOfTwo() {
        let rollUp = FeatureRollUp(
            members: [member("A", state: .waitingOnYou)], lanesPushed: true, verificationPassed: false,
            mergedFraction: MergedFraction(mergedCount: 1, totalCount: 2), issueStanding: .authoring
        )
        #expect(rollUp.sentence.contains("1 of 2 merged"))
    }

    @Test("Closed half drops the merged fraction slot at 2 of 2")
    func mergedFractionSlotDroppedWhenFull() {
        let rollUp = FeatureRollUp(
            members: [member("A", state: .waitingOnYou)], lanesPushed: true, verificationPassed: false,
            mergedFraction: MergedFraction(mergedCount: 2, totalCount: 2), issueStanding: .authoring
        )
        #expect(!rollUp.sentence.contains("merged"))
        #expect(rollUp.sentence == "partial landing · 0 of 1 Cards landed · 1 waiting on you")
    }

    // MARK: - Conflicts beside the sentence

    @Test("Mainline Conflicts render beside the sentence and never change it")
    func conflictsBesideSentence() {
        let withoutConflicts = FeatureRollUp(
            members: [member("A", state: .done)], lanesPushed: false, verificationPassed: false,
            mergedFraction: noMerge(), issueStanding: .authoring
        )
        let withConflicts = FeatureRollUp(
            members: [member("A", state: .done)], lanesPushed: false, verificationPassed: false,
            mergedFraction: noMerge(), conflictingRepositories: ["web", "api"], issueStanding: .authoring
        )
        #expect(withConflicts.sentence == withoutConflicts.sentence)
        #expect(withConflicts.conflictsSuffix == " [conflict: api] [conflict: web]")
        let rendered = "**\(withConflicts.sentence)**\(withConflicts.conflictsSuffix)"
        #expect(rendered == "**\(withoutConflicts.sentence)** [conflict: api] [conflict: web]")
    }
}

// MARK: - No-pull-request notes beside the sentence (P19.7; risks OQ108)

extension FeatureRollUpTests {
    @Test("No-Pushed-Branch notes render one per repository, sorted, beside the sentence and never change it")
    func noPullRequestNotesBesideSentence() {
        let without = FeatureRollUp(
            members: [member("A", state: .done)], lanesPushed: true, verificationPassed: true,
            mergedFraction: MergedFraction(mergedCount: 0, totalCount: 1), issueStanding: .authoring
        )
        let with = FeatureRollUp(
            members: [member("A", state: .done)], lanesPushed: true, verificationPassed: true,
            mergedFraction: MergedFraction(mergedCount: 0, totalCount: 1),
            noPullRequestRepositories: ["web", "api"], issueStanding: .authoring
        )
        #expect(with.sentence == without.sentence)
        #expect(with.state == without.state)
        #expect(with.noPullRequestSuffix == " [no pull request: api] [no pull request: web]")
        #expect(
            "**\(with.sentence)**\(with.noPullRequestSuffix)"
                == "**\(without.sentence)** [no pull request: api] [no pull request: web]"
        )
    }

    @Test("No notes: both suffixes are empty and the rendered first line is the bare bold sentence")
    func noNotesEmptySuffix() {
        let rollUp = FeatureRollUp(
            members: [member("A", state: .done)], lanesPushed: false, verificationPassed: false,
            mergedFraction: noMerge(), issueStanding: .authoring
        )
        #expect(rollUp.noPullRequestSuffix.isEmpty)
        #expect(rollUp.noPullRequestRepositories.isEmpty)
        #expect(FeatureRollUpBlock(rollUp: rollUp).render() == "**\(rollUp.sentence)**\n\n### Cards\n\n"
            + "#### `backend` — finished\n- `A` — Done")
    }

    @Test("Conflicts and notes together render conflicts first, then notes, all beside the sentence")
    func conflictsThenNotes() {
        let rollUp = FeatureRollUp(
            members: [member("A", state: .done)], lanesPushed: false, verificationPassed: false,
            mergedFraction: noMerge(), conflictingRepositories: ["web"],
            noPullRequestRepositories: ["mobile"], issueStanding: .authoring
        )
        let firstLine = FeatureRollUpBlock(rollUp: rollUp).render().components(separatedBy: "\n")[0]
        #expect(firstLine == "**\(rollUp.sentence)** [conflict: web] [no pull request: mobile]")
    }

    @Test("The shared note formatter sorts and joins with single spaces, no leading space")
    func notesFormatter() {
        #expect(FeatureRollUp.noPullRequestNotes(["b", "a"]) == "[no pull request: a] [no pull request: b]")
        #expect(FeatureRollUp.noPullRequestNotes([]).isEmpty)
    }
}
