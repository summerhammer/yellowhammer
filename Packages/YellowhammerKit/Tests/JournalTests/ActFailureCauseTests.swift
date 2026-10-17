import Domain
import Foundation
import Testing

@testable import Journal

private let overBudget = "Work Card \"T\" (seshes-backend) composes 12,153 UTF-16 code units, over the description "
    + "budget of 10,000: Brief 7,000"

@Suite("ActFailureCause classifies one failure event")
struct ActFailureCauseTests {
    private func cause(_ event: JournalEvent, _ siblings: [JournalEvent] = []) -> ActFailureCause? {
        ActFailureCause.classify(event, runEvents: siblings)
    }

    @Test("The board scope reason, or a boardScopeUnresolved event in the run, is boardScopeUnresolved")
    func boardScope() {
        let reason = "The Project's board scope is unresolved, so this Act did no work. Run `yh doctor --fix`"
        #expect(cause(.actIncomplete(reason: reason)) == .boardScopeUnresolved)
        #expect(cause(.actIncomplete(reason: "other"), [.boardScopeUnresolved(steps: "x")]) == .boardScopeUnresolved)
    }

    @Test("A breakdown or transaction over the description budget is overDescriptionBudget, wrapped or not")
    func overBudgetCauses() {
        let wrapped = "the Routing Table has no Route left for the authoring Kind; last failure: breakdown on "
            + "codex/gpt-6.1-sol/high returned invalid output: \(overBudget)"
        #expect(cause(.featureBreakdownRejected(name: "F", reason: wrapped)) == .overDescriptionBudget)
        #expect(cause(.featureAuthoringFailed(name: "F", groupKey: "k", reason: overBudget)) == .overDescriptionBudget)
    }

    @Test("Breakdown rejections split into no Route, invalid output and routes failed")
    func breakdownCauses() {
        func rejected(_ reason: String) -> ActFailureCause? {
            cause(.featureBreakdownRejected(name: "F", reason: reason))
        }
        #expect(rejected("the Routing Table has no Route left for the authoring Kind") == .noAuthoringRoute)
        #expect(rejected("x; last failure: breakdown on a/b/c returned invalid output: bad") == .invalidBreakdown)
        #expect(rejected("bad range") == .invalidBreakdown)
        #expect(rejected("x; last failure: breakdown on a/b/c exited with status 2") == .authoringRoutesFailed)
        #expect(rejected("breakdown on a/b/c crashed with no outcome (signal 9)") == .authoringRoutesFailed)
    }

    @Test("The remaining failure events each have their own class")
    func otherCauses() {
        #expect(cause(.featureAuthoringFailed(name: "F", groupKey: "k", reason: "rolled back"))
            == .authoringTransactionFailed)
        #expect(cause(.featureSelectionFailed(reason: "none")) == .selectionFailed)
        #expect(cause(.authoringInvariantBroken(cardID: 1, issueID: "c", reason: "r")) == .authoringInvariantBroken)
        #expect(cause(.repoLaneEnded(repository: "r", cardsRun: 0, failure: "boom")) == .laneFailed)
        #expect(cause(.repoLaneEnded(repository: "r", cardsRun: 0, failure: nil)) == nil)
        #expect(cause(.actIncomplete(reason: "Linear returned 503")) == .actIncomplete)
        #expect(cause(.actEnded) == nil)
    }
}
