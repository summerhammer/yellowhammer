import Domain
import Foundation
import Testing

@Test("A lost terminal wrapper is Crashed-Unknown and excludes no Route")
func lostTerminalWrapperIsUnknown() {
    let outcome = RunOutcome.classify(end: .wrapperLost, resultFile: nil, pass: .worker)
    #expect(outcome == .crashedUnknown(.wrapperLost))
    let ending = AttemptEnding.crashedUnknown(.wrapperLost)
    #expect(ending.outcome == .crashedUnknown)
    #expect(!ending.excludesRoute)
}
