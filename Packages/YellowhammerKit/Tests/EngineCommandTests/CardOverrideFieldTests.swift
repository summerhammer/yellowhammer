import Domain
import Foundation
@testable import Journal
import Testing

@testable import Engine

// routing/resolve-a-route-for-a-card and board-projection/maintain-the-managed-block (roadmap P22.7): the
// Card override is the one top-level `Card override:` line in a Work Card's Managed Block. Only that line is
// parsed; the exact empty form has no trailing space; a nonempty value has exactly one separator space and
// is read exactly as written; malformed and duplicated lines are retained and refused, never defaulted.

private func reading(_ lines: String...) -> CardOverrideField.Reading {
    CardOverrideField.reading(of: lines)
}

@Suite("Card override field: reading")
struct CardOverrideFieldReadingTests {
    @Test("Absent and the exact empty form both mean normal routing")
    func unset() {
        #expect(CardOverrideField.reading(of: []) == .unset)
        #expect(reading("Card override:") == .unset)
    }

    @Test("One separator space then the route is a value, spelled as supplied")
    func value() {
        #expect(reading("Card override: claude/opus/high") == .value("claude/opus/high"))
        #expect(reading("Card override: Agy/Gemini-3-Pro/HIGH") == .value("Agy/Gemini-3-Pro/HIGH"))
        #expect(reading("Card override: agy/google/gemini-3-pro/high") == .value("agy/google/gemini-3-pro/high"))
    }

    @Test(
        "A trailing space, a second separator space, a missing space and trailing whitespace are malformed",
        arguments: [
            "Card override: ", "Card override:  claude/opus/high", "Card override:claude/opus/high",
            "Card override: claude/opus/high ", "Card override: claude/opus/high\t", "Card override:\tclaude/opus/high"
        ]
    )
    func malformed(line: String) {
        guard case .malformed = reading(line) else {
            Issue.record("expected malformed for \(line.debugDescription)")
            return
        }
    }

    @Test("Linear's backslash escapes and autolink forms are undone to interpret the value, not to store it")
    func escapedValuesReadAsTheirRoute() {
        let expected = CardOverrideField.Reading.value("codex/gpt-5.6_sol/high*")
        #expect(reading("Card override: codex/gpt-5.6\\_sol/high\\*") == expected)
        #expect(reading("Card override: <codex/gpt-5.6_sol/high*>") == .value("codex/gpt-5.6_sol/high*"))
        #expect(reading("Card override: [a/b/c](a/b/c)") == .value("a/b/c"))
        #expect(reading("Card override: a\\z/b/c") == .value("a\\z/b/c"))
    }

    @Test("Escapes do not relax the spacing rules, and a genuinely malformed value stays malformed")
    func escapesKeepSpacingStrict() {
        guard case .malformed = reading("Card override:  codex/gpt-5.6\\_sol/high") else {
            Issue.record("expected malformed")
            return
        }
        #expect(CardOverrideField.sameIgnoringEscapes(["Card override: a\\_b/c/d"], ["Card override: a_b/c/d"]))
        #expect(!CardOverrideField.sameIgnoringEscapes(["Card override: a/b/c"], ["Card override:  a/b/c"]))
    }

    @Test("A duplicated line is malformed whatever the lines say")
    func duplicated() {
        guard case .malformed(let reason) = reading("Card override: a/b/c", "Card override: a/b/c") else {
            Issue.record("expected malformed")
            return
        }
        #expect(reason.contains("2"))
        guard case .malformed = reading("Card override:", "Card override: a/b/c") else {
            Issue.record("expected malformed")
            return
        }
    }
}

@Suite("Card override field: where it is read in a Managed Block")
struct CardOverrideFieldParsingTests {
    private func block(
        override: [String] = [], prose: String = "Add the endpoint.", state: CardState = .todo
    ) -> CardManagedBlock {
        CardManagedBlock(
            kind: "impl", repository: "backend", scope: ["src/api"], cardOverride: override, state: state,
            lanePosition: 1, laneLength: 1, brief: ArchitecturalBrief(prose: prose, transcriptions: []),
            definitionOfDone: [
                DoDClause(cid: "c1", text: "Answers 200", citation: "api/get", citationProvenance: "")
            ],
            attempts: []
        )
    }

    @Test("The empty form renders after the Scope line, with no trailing space, and reads back as no lines")
    func emptyFormRoundTrips() {
        let rendered = block().render()
        let lines = rendered.components(separatedBy: "\n")
        let scope = lines.firstIndex { $0.hasPrefix("**Scope:**") }
        #expect(scope.map { lines[$0 + 1] } == "Card override:")
        #expect(CardManagedBlockParser.parse(block: rendered).cardOverrideLines == ["Card override:"])
        let held = CardManagedBlockParser.parse(block: rendered).cardOverrideLines
        #expect(CardOverrideField.reading(of: held) == .unset)
    }

    @Test("A value, a malformed value and a duplicate round-trip verbatim through render and parse")
    func valuesRoundTrip() {
        for held in [
            ["Card override: codex/o3/high"], ["Card override:  codex/o3/high "],
            ["Card override: a/b/c", "Card override: d/e/f"]
        ] {
            #expect(CardManagedBlockParser.parse(block: block(override: held).render()).cardOverrideLines == held)
        }
    }

    @Test("Every compaction rung keeps the Card override line exactly")
    func compactionKeepsTheField() {
        let held = ["Card override:  codex/o3/high "]
        let record = AttemptRecord(
            id: 1, cardID: 1, budgetEpoch: 0, route: Route(cli: "claude", model: "opus", effort: "high")!,
            classification: nil, result: "hard failure", consumedHow: nil, checkDeclaredNone: true, routeSource: nil,
            overridePin: nil, startedAt: Date(), endedAt: Date(), rounds: [], preservedRef: nil, preservedCommit: nil
        )
        var withAttempts = block(override: held)
        withAttempts.attempts = (1...3).map { AttemptAccount(ordinal: $0, record: record, checkRuns: []) }
        let renderings = withAttempts.renderings()
        #expect(renderings.count > 1)
        for rendering in renderings {
            #expect(CardManagedBlockParser.parse(block: rendering).cardOverrideLines == held)
        }
    }

    @Test("A route-like string in the prose, the Definition of Done or the Attempts history is not the field")
    func otherTextIsNeverScanned() {
        let prose = "Use the route below.\nCard override: agy/opus/max\nIt is for reviewers only."
        let rendered = block(prose: prose).render()
        #expect(rendered.contains("\nCard override: agy/opus/max\n"))

        let parsed = CardManagedBlockParser.parse(block: rendered)

        #expect(parsed.cardOverrideLines == ["Card override:"])
        let underHeading = rendered.replacingOccurrences(
            of: "Answers 200", with: "Answers 200\nCard override: agy/opus/max"
        )
        #expect(CardManagedBlockParser.parse(block: underHeading).cardOverrideLines == ["Card override:"])
    }

    @Test("Indented lines and lines inside fenced code in the header are not top-level fields")
    func indentedAndFencedLinesAreIgnored() {
        let text = """
        **Kind:** `impl`
          Card override: agy/opus/max
        ```
        Card override: codex/o3/high
        ```
        - Card override: claude/opus/high
        Card override: claude/sonnet/medium
        ### Architectural Brief
        """

        let parsed = CardManagedBlockParser.parse(block: text)

        #expect(parsed.cardOverrideLines == ["Card override: claude/sonnet/medium"])
    }

    @Test("A block that lost the line reads as no lines, which is an explicit clear")
    func removedLineReadsAsNone() {
        let text = block().render().components(separatedBy: "\n").filter { $0 != "Card override:" }
            .joined(separator: "\n")

        #expect(CardManagedBlockParser.parse(block: text).cardOverrideLines.isEmpty)
    }
}

@Suite("Card override field: the Journal's copy and the Readiness Check")
struct CardOverrideFieldJournalTests {
    @Test("The empty form and no line are the same held value, and a change reports whether it changed")
    func heldValue() throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let cardID = try insertFixtureCard(journal, issueID: "issue-1")

        #expect(try !journal.recordCardOverrideLines(cardID: cardID, lines: ["Card override:"]))
        #expect(try journal.cardOverrideLines(cardID: cardID).isEmpty)
        #expect(try journal.recordCardOverrideLines(cardID: cardID, lines: ["Card override: a/b/c", "Card override:"]))
        #expect(try !journal.recordCardOverrideLines(cardID: cardID, lines: ["Card override: a/b/c", "Card override:"]))
        #expect(try journal.cardOverrideLines(cardID: cardID) == ["Card override: a/b/c", "Card override:"])
        #expect(try journal.recordCardOverrideLines(cardID: cardID, lines: []))
        #expect(try journal.cardOverrideLines(cardID: cardID).isEmpty)
    }
}
