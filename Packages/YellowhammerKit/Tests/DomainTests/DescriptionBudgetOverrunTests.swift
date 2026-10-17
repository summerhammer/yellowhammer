import Domain
import Testing

@Suite("DescriptionBudgetOverrun")
struct DescriptionBudgetOverrunTests {
    private let live = "the Routing Table has no Route left for the authoring Kind; last failure: breakdown on "
        + "codex/gpt-6.1-sol/high returned invalid output: Work Card \"Serve pending Proposals in the schedule "
        + "read\" (seshes-backend) composes 12,153 UTF-16 code units, over the description budget of 10,000: "
        + "Brief 7,000; Transcription references 4,000"

    @Test("A Work Card rejection parses with its repository and grouped numbers")
    func workCard() {
        let text = "Work Card \"Add it\" (backend) composes 2,500 UTF-16 code units, "
            + "over the description budget of 2,000: A 1"
        #expect(DescriptionBudgetOverrun.parse(text) == DescriptionBudgetOverrun(
            subject: .workCard, title: "Add it", repository: "backend", size: 2_500, budget: 2_000
        ))
    }

    @Test("A Feature Card rejection has no repository")
    func featureCard() {
        let text = "Feature Card \"Big\" composes 300 characters, over the description budget of 200: the roll-up 300"
        let overrun = DescriptionBudgetOverrun.parse(text)
        #expect(overrun == DescriptionBudgetOverrun(
            subject: .featureCard, title: "Big", repository: nil, size: 300, budget: 200
        ))
        #expect(overrun?.oneLine == "Feature Card \"Big\" is 300 of 200 description budget")
    }

    @Test("The live wrapped reason parses and words one line")
    func liveReason() {
        let overrun = DescriptionBudgetOverrun.parse(live)
        #expect(overrun?.size == 12_153)
        #expect(overrun?.budget == 10_000)
        #expect(overrun?.repository == "seshes-backend")
        #expect(overrun?.oneLine == "Work Card \"Serve pending Proposals in the schedule read\" (seshes-backend) "
            + "is 12,153 of 10,000 description budget")
        #expect(DescriptionBudgetOverrun.oneLineReason(live) == overrun?.oneLine)
    }

    @Test("Text that is no overrun parses to nil")
    func garbage() {
        #expect(DescriptionBudgetOverrun.parse("nothing to see") == nil)
        #expect(DescriptionBudgetOverrun.parse("Work Card \"T\" composes many") == nil)
    }

    @Test("oneLineReason falls back to the text after the invalid-output marker, then the reason, first line only")
    func fallbacks() {
        #expect(DescriptionBudgetOverrun.oneLineReason("breakdown on a/b/c returned invalid output: bad range\nmore")
            == "bad range")
        #expect(DescriptionBudgetOverrun.oneLineReason("exited with status 2\ndetail") == "exited with status 2")
        #expect(DescriptionBudgetOverrun.oneLineReason("plain") == "plain")
    }
}
