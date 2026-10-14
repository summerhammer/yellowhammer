import Foundation

/// A run of lines within one file, 1-based and inclusive at both ends (spec: feature-authoring/
/// author-an-architectural-brief). A contract may name several per path; a path with none is transcribed
/// whole. A range is a claim about a file at one commit and is never clamped to fit it — validating it
/// against the file is the reader's job, not this type's.
public struct LineRange: Equatable, Hashable, Sendable, Codable, Comparable {
    public let start: Int
    public let end: Int

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }

    public static func < (lhs: LineRange, rhs: LineRange) -> Bool {
        (lhs.start, lhs.end) < (rhs.start, rhs.end)
    }

    /// The ranges sorted into file order, with overlapping and adjacent runs merged and duplicates
    /// collapsed: `[1-5, 6-9]` and `[1-7, 3-9]` are both `[1-9]`.
    public static func union(_ ranges: [LineRange]) -> [LineRange] {
        var merged: [LineRange] = []
        for range in ranges.sorted() {
            if let last = merged.last, range.start <= last.end + 1 {
                merged[merged.count - 1] = LineRange(start: last.start, end: max(last.end, range.end))
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    // MARK: - Text forms

    /// The token standing for "no range": the whole file.
    private static let wholeFileToken = "-"

    /// The per-path token the Card stamp and the Journal share: `120-180+200-210` for ranges, `-` for a
    /// whole file.
    public static func token(for ranges: [LineRange]) -> String {
        guard !ranges.isEmpty else { return wholeFileToken }
        return ranges.map { "\($0.start)-\($0.end)" }.joined(separator: "+")
    }

    /// The ranges a ``token(for:)`` stands for — `[]` for `-` — or nil when `token` is malformed.
    public static func ranges(fromToken token: String) -> [LineRange]? {
        if token == wholeFileToken { return [] }
        var ranges: [LineRange] = []
        for part in token.split(separator: "+", omittingEmptySubsequences: false) {
            let bounds = part.split(separator: "-", omittingEmptySubsequences: false)
            guard bounds.count == 2, let start = number(bounds[0]), let end = number(bounds[1]) else {
                return nil
            }
            ranges.append(LineRange(start: start, end: end))
        }
        return ranges
    }

    /// Plain ASCII digits only: `Int("+5")` and `Int("-5")` would otherwise read as numbers.
    private static func number(_ text: Substring) -> Int? {
        guard !text.isEmpty, text.allSatisfy({ $0 >= "0" && $0 <= "9" }) else { return nil }
        return Int(text)
    }

    /// The human form for display: `lines 120–180, 200–210` (en dash); a single-line range is `line 7`.
    public static func displayText(_ ranges: [LineRange]) -> String {
        let parts = ranges.map { $0.start == $0.end ? "\($0.start)" : "\($0.start)–\($0.end)" }
        let noun = ranges.count == 1 && ranges[0].start == ranges[0].end ? "line" : "lines"
        return "\(noun) \(parts.joined(separator: ", "))"
    }
}
