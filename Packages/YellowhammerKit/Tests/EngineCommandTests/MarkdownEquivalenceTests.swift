@testable import Engine
import Testing

// Issue #433: Linear parses a Card description's Markdown and re-serialises it, so the board's copy of
// a Transcription Block or a Definition of Done clause is rarely byte-identical to what Yellowhammer
// wrote. Each rewrite class seen in production pairs our text with Linear's form below; the guards at
// the end pin that a genuine change to the rendered text is still an edit.

@Suite("Markdown equivalence")
struct MarkdownEquivalenceTests {
    @Test("An indented code block comes back fenced and dedented, with blank lines around the fence")
    func indentedCodeBecomesFenced() {
        let ours = "Intro:\n\n    let x = 1\n    let y = 2\n\nOutro"
        let linear = "Intro:\n\n```\nlet x = 1\nlet y = 2\n```\n\nOutro"
        #expect(MarkdownEquivalence.rendersSame(ours, linear))
    }

    @Test("Square brackets come back backslash-escaped")
    func bracketsAreEscaped() {
        let ours = "Offsets are [22:19, 22:34] on the night"
        let linear = #"Offsets are \[22:19, 22:34\] on the night"#
        #expect(MarkdownEquivalence.rendersSame(ours, linear))
    }

    @Test("Other backslash escapes come and go, such as Swift string interpolation outside code")
    func otherEscapesComeAndGo() {
        let ours = #"The label interpolates "\(x)" outside code"#
        let linear = #"The label interpolates "(x)" outside code"#
        #expect(MarkdownEquivalence.rendersSame(ours, linear))
        #expect(MarkdownEquivalence.rendersSame(linear, ours))
    }

    @Test("A dash bullet comes back as an asterisk bullet")
    func bulletCharacterChanges() {
        #expect(MarkdownEquivalence.rendersSame("- one\n- two\n- three", "* one\n* two\n* three"))
    }

    @Test("A heading comes back with a blank line after it")
    func headingGainsBlankLine() {
        #expect(MarkdownEquivalence.rendersSame("### Heading\nBody text", "### Heading\n\nBody text"))
    }

    @Test("The managed end marker comes back indented by two spaces")
    func endMarkerIsIndented() {
        let ours = "Body text\n<!-- yh:managed:end -->"
        let linear = "Body text\n  <!-- yh:managed:end -->"
        #expect(MarkdownEquivalence.rendersSame(ours, linear))
    }

    @Test("A domain-like token is autolinked")
    func domainLikeTokenIsAutolinked() {
        #expect(MarkdownEquivalence.rendersSame("Read night.id first", "Read [night.id](<http://night.id>) first"))
        #expect(MarkdownEquivalence.rendersSame(
            "Call fixture.open() first", "Call [fixture.open](<http://fixture.open>)() first"
        ))
    }

    @Test("A double-backtick code span comes back as a single-backtick one")
    func doubleBacktickSpanIsNormalised() {
        let ours = "See ``Schedule/firings()`` for the offsets"
        let linear = "See `Schedule/firings()` for the offsets"
        #expect(MarkdownEquivalence.rendersSame(ours, linear))
    }

    @Test("An emphasis run that spans lines is re-emitted per line")
    func multiLineEmphasisIsReEmitted() {
        let ours = "Note _the first line\nand the second line_ end"
        let linear = "Note *the first line*\n*and the second line* end"
        #expect(MarkdownEquivalence.rendersSame(ours, linear))
    }

    @Test("The YLH-337 clause with its brackets escaped renders the same")
    func ylh337Clause() {
        let ours = "With night_start 22:00, night_end 06:00, build_every_minutes 15 and offset 3, "
            + "`firings().build` is exactly [22:19, 22:34, …, 05:49]; "
            + "land still contains its periodic ticks"
        let linear = "With night_start 22:00, night_end 06:00, build_every_minutes 15 and offset 3, "
            + #"`firings().build` is exactly \[22:19, 22:34, …, 05:49\]; "#
            + "land still contains its periodic ticks"
        #expect(MarkdownEquivalence.rendersSame(ours, linear))
    }

    // MARK: - Guards: a real edit is still an edit

    @Test("A changed word inside a code block is an edit")
    func changedWordInCodeBlock() {
        let ours = "Intro:\n\n    let x = 1\n    let y = 2\n\nOutro"
        let linear = "Intro:\n\n```\nlet x = 1\nlet z = 2\n```\n\nOutro"
        #expect(!MarkdownEquivalence.rendersSame(ours, linear))
    }

    @Test("A changed number inside the escaped bracket run is an edit")
    func changedNumberInsideEscapedBrackets() {
        let ours = "offset 3, `firings().build` is exactly [22:19, 22:34, …, 05:49]; land ticks"
        let edited = #"offset 3, `firings().build` is exactly \[22:20, 22:34, …, 05:49\]; land ticks"#
        #expect(!MarkdownEquivalence.rendersSame(ours, edited))
    }

    @Test("A changed real link target is an edit")
    func changedLinkTarget() {
        let ours = "See [the docs](https://example.com/one) for details"
        let linear = "See [the docs](https://example.com/two) for details"
        #expect(!MarkdownEquivalence.rendersSame(ours, linear))
    }

    @Test("Text added inside a fenced block is an edit")
    func textAddedInsideFence() {
        let ours = "```\nlet x = 1\n```"
        let edited = "```\nlet x = 1\nlet y = 2\n```"
        #expect(!MarkdownEquivalence.rendersSame(ours, edited))
    }

    @Test("Identical text renders the same, and an empty text differs from a non-empty one")
    func identityAndEmpty() {
        #expect(MarkdownEquivalence.rendersSame("", ""))
        #expect(MarkdownEquivalence.rendersSame("same", "same"))
        #expect(!MarkdownEquivalence.rendersSame("", "something"))
    }
}
