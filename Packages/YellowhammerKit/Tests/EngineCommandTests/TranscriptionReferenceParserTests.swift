import Domain
import Foundation
import Testing

@testable import Engine

// An Operator may edit a Transcription Block's visible `Contract:` line on the board; that line is the
// reference (spec: feature-authoring/author-an-architectural-brief#edited-reference). These cover the
// line grammar, its tolerance, and the render -> parse round trip.

private func reference(_ line: String) throws -> TranscriptionReference {
    try CardManagedBlockParser.parseReference(line: line).get()
}

private func failure(_ line: String) -> String? {
    if case .failure(let failure) = CardManagedBlockParser.parseReference(line: line) { return failure.reason }
    return nil
}

private func block(
    paths: [String] = ["a.swift"], ranges: [String: [LineRange]] = [:], symbol: String? = nil,
    commit: String? = "abc1234", supplied: Bool = false, night: String? = nil
) -> TranscriptionBlock {
    TranscriptionBlock(
        repository: "api", paths: paths, ranges: ranges, symbol: symbol, mainlineCommit: commit, content: "x",
        contentHash: "h", authorSupplied: supplied, authorSuppliedNight: night.flatMap(NightStart.init(rawValue:))
    )
}

private func roundTrip(_ block: TranscriptionBlock) throws -> ParsedTranscription {
    let rendered = TranscriptionBlockLine.render(block).joined(separator: "\n")
    let parsed = CardManagedBlockParser.parse(block: rendered).transcriptions
    return try #require(parsed.first)
}

@Suite("Parsing a Contract: line")
struct ReferenceLineTests {
    @Test("Every shape the renderer writes round-trips through render -> parse", arguments: [
        block(),
        block(paths: ["a.swift", "b.swift"]),
        block(ranges: ["a.swift": [LineRange(start: 7, end: 7)]]),
        block(
            paths: ["a.swift", "b.swift"],
            ranges: ["a.swift": [LineRange(start: 120, end: 180), LineRange(start: 200, end: 210)]]
        ),
        block(symbol: "ClassList"),
        block(symbol: "ClassList", supplied: true, night: "2026-09-15"),
        block(supplied: true),
        block(commit: nil, supplied: true)
    ])
    func roundTrips(_ block: TranscriptionBlock) throws {
        let parsed = try roundTrip(block)
        #expect(parsed.failure == nil)
        #expect(parsed.repository == block.repository)
        #expect(parsed.paths == block.paths)
        #expect(parsed.ranges == block.ranges)
        #expect(parsed.symbol == block.symbol)
        #expect(parsed.commit == block.mainlineCommit)
        #expect(parsed.line == TranscriptionBlockLine.render(block)[2])
    }

    @Test("Hyphen, en dash and em dash all separate a range's bounds, with or without spaces")
    func dashes() throws {
        for dash in ["-", "–", "—", " - ", " – "] {
            let parsed = try reference("Contract: `api` · `a.md` lines 3\(dash)5, 9")
            #expect(parsed.ranges == ["a.md": [LineRange(start: 3, end: 5), LineRange(start: 9, end: 9)]])
        }
    }

    @Test("Extra whitespace and a Linear-style indented line parse to the same fields")
    func tolerance() throws {
        let tidy = try reference("Contract: `api` · `a.md` lines 3–5 · symbol `S` · commit `abc1234`")
        let sloppy = try reference(
            "  Contract:   `api`   ·\t`a.md`   lines  3 – 5  ·  symbol  `S`  ·  commit   `abc1234`  "
        )
        #expect(sloppy == tidy)

        let block = "  <!-- yh:transcription:start repo=api paths=a.md symbol=S commit=abc1234 -->\n"
            + "  Contract: `api` · `a.md` lines 3–5 · symbol `S` · commit `abc1234`\n"
            + "  <!-- yh:transcription:end -->"
        let parsed = try #require(CardManagedBlockParser.parse(block: block).transcriptions.first)
        #expect(parsed.repository == "api")
        #expect(parsed.ranges == ["a.md": [LineRange(start: 3, end: 5)]])
        #expect(parsed.line == "Contract: `api` · `a.md` lines 3–5 · symbol `S` · commit `abc1234`")
    }

    @Test("A reversed or zero range parses fine: the reader reports it")
    func badRangesParse() throws {
        let parsed = try reference("Contract: `api` · `a.md` lines 9–3, 0–2 · commit `abc1234`")
        #expect(parsed.ranges == ["a.md": [LineRange(start: 9, end: 3), LineRange(start: 0, end: 2)]])
    }

    @Test("A commit of `-`, or no commit part, names no commit; the Operator-supplied mark is ignored")
    func commits() throws {
        #expect(try reference("Contract: `api` · `a.md` · commit `-`").commit == nil)
        #expect(try reference("Contract: `api` · `a.md`").commit == nil)
        let marked = try reference("Contract: `api` · `a.md` · commit `abc` · Operator-supplied, as of 2026-09-15")
        #expect(marked.commit == "abc")
    }

    @Test("Each unparseable shape fails with a reason", arguments: [
        "api · `a.md` · commit `abc`",
        "Contract: `api`",
        "Contract: `api` · commit `abc`",
        "Contract: `api` · `a.md` · `a.md` · commit `abc`",
        "Contract: `api` · `a.md` · something else",
        "Contract: `api` · `a.md` lines 3– · commit `abc`",
        "Contract: `api` · `a.md` lines x–5 · commit `abc`",
        "Contract: `api` · `a.md` lines 3–5, , 9 · commit `abc`",
        "Contract: `api` · `a.md` somewhere · commit `abc`",
        "Contract: `api` · `a.md` · commit `abc` · commit `def`",
        "Contract: `api` · `a.md` · symbol `A` · symbol `B` · commit `abc`",
        "Contract: `api` · `a.md` · commit abc",
        "Contract: `api` · `a.md` ·"
    ])
    func failures(_ line: String) {
        let reason = failure(line)
        #expect(reason?.isEmpty == false, "parsed: \(line)")
    }

    @Test("The failure names the problem")
    func failureReasons() {
        #expect(failure("Contract: `api`") == "it names no path")
        #expect(failure("Contract: `api` · `a.md` · `a.md`") == "it names the path `a.md` twice")
        #expect(failure("Contract: `api` · `a.md` · commit `a` · commit `b`") == "it names more than one commit")
        #expect(failure("Contract: `api` · `a.md` · symbol `a` · symbol `b`") == "it names more than one symbol")
    }

    @Test("A block whose line cannot be parsed carries the line and the failure; its fields mean nothing")
    func unparseableBlock() throws {
        let block = "<!-- yh:transcription:start repo=api paths=a.md symbol=- commit=abc -->\n"
            + "Contract: `api` · nonsense\n<!-- yh:transcription:end -->"
        let parsed = try #require(CardManagedBlockParser.parse(block: block).transcriptions.first)
        #expect(parsed.failure != nil)
        #expect(parsed.line == "Contract: `api` · nonsense")
    }

    @Test("The line wins over the stamp, full stop")
    func lineWinsOverStamp() throws {
        let block = "<!-- yh:transcription:start repo=api paths=old.md symbol=- commit=old1234 -->\n"
            + "Contract: `other` · `new.md` · commit `new5678`\n<!-- yh:transcription:end -->"
        let parsed = try #require(CardManagedBlockParser.parse(block: block).transcriptions.first)
        #expect(parsed.repository == "other")
        #expect(parsed.paths == ["new.md"])
        #expect(parsed.commit == "new5678")
    }

    @Test("A legacy stamp-only block is read from its stamp; `-` and Operator-supplied commits are nil")
    func legacyStampOnly() throws {
        for commit in ["-", "Operator-supplied", "Operator-supplied as of 2026-09-17"] {
            let block = "<!-- yh:transcription:start repo=api paths=a.md ranges=3-5 symbol=S commit=\(commit) -->\n"
                + "legacy content\n<!-- yh:transcription:end -->"
            let parsed = try #require(CardManagedBlockParser.parse(block: block).transcriptions.first)
            #expect(parsed == ParsedTranscription(
                repository: "api", paths: ["a.md"], ranges: ["a.md": [LineRange(start: 3, end: 5)]], symbol: "S",
                commit: nil
            ), "commit=\(commit)")
        }
    }

    @Test("An unread block's verbatim line survives render -> parse")
    func unreadLineSurvives() throws {
        let edited = "Contract: `api` · `a.swift` lines 3-4 · commit `abc1234`"
        let unread = TranscriptionBlock(
            repository: "api", paths: ["a.swift"], mainlineCommit: "deadbeef", content: "", contentHash: "",
            authorSupplied: true, editedReference: edited
        )
        let parsed = try roundTrip(unread)
        #expect(parsed.line == edited)
        #expect(parsed.commit == "abc1234")
        #expect(parsed.ranges == ["a.swift": [LineRange(start: 3, end: 4)]])
    }
}

@Suite("Unrenderable references")
struct UnrenderableReferenceTests {
    @Test("A plain reference renders and reads back")
    func plain() {
        #expect(!AuthoringTranscriptions.isUnrenderable(block(
            paths: ["a.swift", "b.swift"], ranges: ["a.swift": [LineRange(start: 1, end: 4)]], symbol: "Foo"
        )))
    }

    @Test("A path or symbol with a middle dot or a backtick, a path with a comma, or a -->/newline is refused")
    func refused() {
        #expect(AuthoringTranscriptions.isUnrenderable(block(paths: ["a·b.swift"])))
        #expect(AuthoringTranscriptions.isUnrenderable(block(paths: ["a`b.swift"])))
        #expect(AuthoringTranscriptions.isUnrenderable(block(symbol: "A·B")))
        #expect(AuthoringTranscriptions.isUnrenderable(block(symbol: "A`B")))
        #expect(AuthoringTranscriptions.isUnrenderable(block(paths: ["a,b.swift"])))
        #expect(AuthoringTranscriptions.isUnrenderable(block(symbol: "x --> y")))
        #expect(AuthoringTranscriptions.isUnrenderable(block(paths: ["a\nb.swift"])))
        #expect(AuthoringTranscriptions.isUnrenderable(block(symbol: "x commit=y")))
    }
}
