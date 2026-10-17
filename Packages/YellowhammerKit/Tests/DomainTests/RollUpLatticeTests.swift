import Testing

@testable import Domain

// board-projection/overview.md #roll-up-lattice: one test per lattice row. The strings are the Managed Block's
// and the Pulse's, so they are asserted verbatim.

private let fullyMerged = MergedFraction(mergedCount: 2, totalCount: 2)

private func running(_ states: [CardState]) -> (state: RollUpState, sentence: String) {
    RollUpLattice.rollUp(
        liveCardStates: states, lanesPushed: false, verificationPassed: false, unmetClauseCount: nil,
        mergedFraction: fullyMerged
    )
}

private func closed(
    _ states: [CardState], verificationPassed: Bool = false, unmetClauseCount: Int? = nil,
    mergedFraction: MergedFraction = fullyMerged
) -> (state: RollUpState, sentence: String) {
    RollUpLattice.rollUp(
        liveCardStates: states, lanesPushed: true, verificationPassed: verificationPassed,
        unmetClauseCount: unmetClauseCount, mergedFraction: mergedFraction
    )
}

@Suite("Roll-up lattice: running half")
struct RollUpLatticeRunningHalfTests {
    @Test("A Card waiting on you makes the Feature waiting, ahead of blocked and running Cards")
    func waiting() {
        let result = running([.done, .waitingOnYou, .blocked, .inProgress])
        #expect(result.state == .waiting)
        #expect(result.sentence == "waiting · 1 of 4 Cards landed · 1 waiting on you")
    }

    @Test("A blocked Card with none waiting makes the Feature blocked, ahead of running Cards")
    func blocked() {
        let result = running([.done, .blocked, .blocked, .inProgress])
        #expect(result.state == .blocked)
        #expect(result.sentence == "blocked · 1 of 4 Cards landed · 2 blocked")
    }

    @Test("In-progress Cards with none waiting or blocked make the Feature running")
    func runningWithCardsInProgress() {
        let result = running([.done, .inProgress, .todo])
        #expect(result.state == .running)
        #expect(result.sentence == "running · 1 of 3 Cards landed · 1 running")
    }

    @Test("Nothing waiting, blocked or in progress is running and all on track")
    func allOnTrack() {
        let result = running([.todo, .todo, .done])
        #expect(result.state == .running)
        #expect(result.sentence == "running · 1 of 3 Cards landed · all on track")
    }

    @Test("The merged fraction, verification and clause count never appear in the running half")
    func closedSlotsAreAbsent() {
        let result = RollUpLattice.rollUp(
            liveCardStates: [.inProgress], lanesPushed: false, verificationPassed: true, unmetClauseCount: 4,
            mergedFraction: MergedFraction(mergedCount: 0, totalCount: 2)
        )
        #expect(result.sentence == "running · 0 of 1 Cards landed · 1 running")
    }
}

@Suite("Roll-up lattice: closed half")
struct RollUpLatticeClosedHalfTests {
    @Test("A Card waiting on you after the Cycle landed is a partial landing")
    func partialWaiting() {
        let result = closed([.done, .waitingOnYou, .blocked])
        #expect(result.state == .partial)
        #expect(result.sentence == "partial · 1 of 3 Cards landed · 1 waiting on you")
    }

    @Test("A blocked Card with none waiting is a partial landing")
    func partialBlocked() {
        let result = closed([.done, .blocked], verificationPassed: true)
        #expect(result.state == .partial)
        #expect(result.sentence == "partial · 1 of 2 Cards landed · 1 blocked")
    }

    @Test("Every Card done and Verification passed is verified")
    func verified() {
        let result = closed([.done, .done], verificationPassed: true)
        #expect(result.state == .verified)
        #expect(result.sentence == "verified · 2 of 2 Cards landed · all verified")
    }

    @Test("Every Card done but Verification unmet names the unmet clauses")
    func waitingOnUnmetClauses() {
        let result = closed([.done, .done], unmetClauseCount: 4)
        #expect(result.state == .waiting)
        #expect(result.sentence == "waiting · 2 of 2 Cards landed · 4 clauses unmet")
    }

    @Test("Every Card done with both unmet and not checked clauses names both")
    func waitingOnUnmetAndNotCheckedClauses() {
        let result = RollUpLattice.rollUp(
            liveCardStates: [.done, .done], lanesPushed: true, verificationPassed: false,
            unmetClauseCount: 2, notCheckedClauseCount: 3, mergedFraction: fullyMerged
        )
        #expect(result.state == .waiting)
        #expect(result.sentence == "waiting · 2 of 2 Cards landed · 2 clauses unmet, 3 clauses not checked")
    }

    @Test("Every Card done with only not checked clauses names not checked")
    func waitingOnOnlyNotCheckedClauses() {
        let result = RollUpLattice.rollUp(
            liveCardStates: [.done, .done], lanesPushed: true, verificationPassed: false,
            unmetClauseCount: 0, notCheckedClauseCount: 1, mergedFraction: fullyMerged
        )
        #expect(result.state == .waiting)
        #expect(result.sentence == "waiting · 2 of 2 Cards landed · 1 clauses not checked")
    }

    @Test("Every Card done with 0 unmet and 0 not checked keeps 0 clauses unmet")
    func waitingOnZeroUnmetAndZeroNotChecked() {
        let result = RollUpLattice.rollUp(
            liveCardStates: [.done, .done], lanesPushed: true, verificationPassed: false,
            unmetClauseCount: 0, notCheckedClauseCount: 0, mergedFraction: fullyMerged
        )
        #expect(result.state == .waiting)
        #expect(result.sentence == "waiting · 2 of 2 Cards landed · 0 clauses unmet")
    }

    @Test("Every Card done with no Verification recorded says so")
    func waitingOnNoVerificationRecord() {
        let result = closed([.done, .done])
        #expect(result.state == .waiting)
        #expect(result.sentence == "waiting · 2 of 2 Cards landed · verification not recorded")
    }

    @Test("Cards not yet done keep a verified-looking Feature waiting, not partial")
    func notAllDoneIsWaiting() {
        let result = closed([.done, .inProgress], verificationPassed: true)
        #expect(result.state == .waiting)
        #expect(result.sentence == "waiting · 1 of 2 Cards landed · verification not recorded")
    }

    @Test("The merged fraction appears only when the pushed repositories are not all merged")
    func mergedFractionSlot() {
        let unmerged = MergedFraction(mergedCount: 1, totalCount: 2)

        let partial = closed([.done, .done], verificationPassed: true, mergedFraction: unmerged)
        #expect(partial.sentence == "verified · 2 of 2 Cards landed · 1 of 2 merged · all verified")

        let merged = closed([.done, .done], verificationPassed: true, mergedFraction: fullyMerged)
        #expect(merged.sentence == "verified · 2 of 2 Cards landed · all verified")

        let waiting = closed([.blocked], mergedFraction: MergedFraction(mergedCount: 0, totalCount: 1))
        #expect(waiting.sentence == "partial · 0 of 1 Cards landed · 0 of 1 merged · 1 blocked")
    }
}
