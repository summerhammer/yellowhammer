import Domain
import Testing

@Suite("LineRange")
struct LineRangeTests {
    private func range(_ start: Int, _ end: Int) -> LineRange { LineRange(start: start, end: end) }

    @Test("Ranges order by start, then end")
    func ordering() {
        #expect([range(5, 9), range(1, 9), range(1, 3)].sorted() == [range(1, 3), range(1, 9), range(5, 9)])
    }

    @Test("Union sorts into file order")
    func unionSorts() {
        #expect(LineRange.union([range(20, 30), range(1, 5)]) == [range(1, 5), range(20, 30)])
    }

    @Test("Union merges overlapping runs and collapses duplicates")
    func unionMergesOverlapAndDuplicates() {
        #expect(LineRange.union([range(1, 7), range(3, 9), range(1, 7)]) == [range(1, 9)])
        #expect(LineRange.union([range(4, 6), range(1, 10)]) == [range(1, 10)])
    }

    @Test("Union merges adjacent runs but not runs a line apart")
    func unionMergesAdjacent() {
        #expect(LineRange.union([range(1, 5), range(6, 9)]) == [range(1, 9)])
        #expect(LineRange.union([range(1, 5), range(7, 9)]) == [range(1, 5), range(7, 9)])
    }

    @Test("Union of nothing is nothing")
    func unionEmpty() {
        #expect(LineRange.union([]) == [])
    }

    @Test("The token codec round-trips ranges and whole files")
    func tokenRoundTrip() {
        let ranges = [range(120, 180), range(200, 210)]
        #expect(LineRange.token(for: ranges) == "120-180+200-210")
        #expect(LineRange.ranges(fromToken: "120-180+200-210") == ranges)
        #expect(LineRange.token(for: [range(7, 7)]) == "7-7")
        #expect(LineRange.ranges(fromToken: "7-7") == [range(7, 7)])
        #expect(LineRange.token(for: []) == "-")
        #expect(LineRange.ranges(fromToken: "-") == [])
    }

    @Test("A malformed token is nil")
    func malformedTokens() {
        for token in ["", "1", "1-", "-5", "a-b", "1-2+", "+1-2", "1-2++3-4", "1-2-3", "+5-6", "1 - 2", "١-٢"] {
            #expect(LineRange.ranges(fromToken: token) == nil, "\(token)")
        }
    }

    @Test("Display text uses an en dash, and `line` for a lone single line")
    func displayText() {
        #expect(LineRange.displayText([range(120, 180), range(200, 210)]) == "lines 120–180, 200–210")
        #expect(LineRange.displayText([range(7, 7)]) == "line 7")
        #expect(LineRange.displayText([range(7, 7), range(9, 12)]) == "lines 7, 9–12")
    }

    @Test("Per-path tokens align with the paths; no ranges anywhere is no tokens")
    func perPathTokens() {
        let ranges = ["a": [range(1, 5)], "c": [range(7, 7), range(9, 10)]]
        let tokens = LineRange.tokens(for: ranges, paths: ["a", "b", "c"])
        #expect(tokens == ["1-5", "-", "7-7+9-10"])
        #expect(LineRange.ranges(fromTokens: tokens, paths: ["a", "b", "c"]) == ranges)
        #expect(LineRange.tokens(for: [:], paths: ["a"]) == nil)
        #expect(LineRange.tokens(for: ["a": []], paths: ["a"]) == nil)
        #expect(LineRange.ranges(fromTokens: nil, paths: ["a"]) == [:])
    }

    @Test("Tokens that do not match the paths, or are malformed, are nil")
    func misalignedTokens() {
        #expect(LineRange.ranges(fromTokens: ["1-5"], paths: ["a", "b"]) == nil)
        #expect(LineRange.ranges(fromTokens: ["1-x", "-"], paths: ["a", "b"]) == nil)
    }
}
