@testable import Engine
import Testing

@Suite("Breakdown validation: briefs that contradict the worker contract (issue #444)")
struct FeatureBreakdownValidationTests {
    @Test(
        "A brief telling the worker not to commit is matched",
        arguments: [
            "Do not commit; the lead commits.",
            "Don't commit.",
            "Never commit",
            "Do not commit your changes.",
            "Leave the work uncommitted.",
            "The sidekick never commits."
        ]
    )
    func contradictionIsMatched(brief: String) {
        #expect(FeatureBreakdownValidation.briefContradiction(in: brief) != nil)
    }

    @Test(
        "Legitimate approach lines are not matched",
        arguments: [
            "Do not commit the generated fixtures.",
            "Don't commit secrets to the repo.",
            "Commit each step separately.",
            "Never commit build products."
        ]
    )
    func approachLineIsAccepted(brief: String) {
        #expect(FeatureBreakdownValidation.briefContradiction(in: brief) == nil)
    }
}
