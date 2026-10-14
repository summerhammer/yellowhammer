import Domain
import Foundation

/// A Transcription Block's reference as the visible `Contract:` line states it
/// (spec: feature-authoring/author-an-architectural-brief#edited-reference).
public struct TranscriptionReference: Equatable, Sendable {
    public var repository: String
    public var paths: [String]
    /// The ranges per path exactly as written — not unioned, not validated: a reversed or zero range
    /// parses fine, and the reader reports it.
    public var ranges: [String: [LineRange]]
    public var symbol: String?
    /// The commit named, or nil when the line says `-` (or names none).
    public var commit: String?

    public init(
        repository: String, paths: [String], ranges: [String: [LineRange]] = [:], symbol: String? = nil,
        commit: String? = nil
    ) {
        self.repository = repository
        self.paths = paths
        self.ranges = ranges
        self.symbol = symbol
        self.commit = commit
    }
}

/// Why a `Contract:` line could not be parsed, in words the Card can show the Operator.
public struct ReferenceParseFailure: Error, Equatable, Sendable, CustomStringConvertible {
    public let reason: String

    public init(_ reason: String) {
        self.reason = reason
    }

    public var description: String { reason }
}

extension CardManagedBlockParser {
    /// Parses one visible `Contract:` line (the grammar is on ``TranscriptionBlockLine``).
    ///
    /// Tolerant by design — Linear re-serialises Markdown, so what matters is the fields, never the
    /// bytes: the line is trimmed, split on `·` (U+00B7), and each part trimmed. En dash, hyphen and em
    /// dash all separate a range's bounds. The Operator-supplied mark is ignored: it is the machine's, not
    /// part of the reference.
    public static func parseReference(line: String) -> Result<TranscriptionReference, ReferenceParseFailure> {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(referencePrefix) else {
            return .failure(ReferenceParseFailure("the line does not start with `Contract:`"))
        }
        let parts = trimmed.dropFirst(referencePrefix.count).split(separator: "·", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let first = parts.first, let repository = codeSpan(first) else {
            return .failure(ReferenceParseFailure("the repository is missing: expected `Contract: `<repository>` · …`"))
        }
        var accumulator = ReferenceAccumulator(repository: repository)
        for part in parts.dropFirst() {
            if let failure = accumulator.absorb(part) { return .failure(failure) }
        }
        return accumulator.finish()
    }

    static let referencePrefix = "Contract:"

    /// The text of a part that is exactly one backtick code span, e.g. `` `api` `` → `api`.
    fileprivate static func codeSpan(_ text: String) -> String? {
        guard text.count > 2, text.hasPrefix("`"), text.hasSuffix("`") else { return nil }
        let inner = String(text.dropFirst().dropLast())
        return inner.contains("`") ? nil : inner
    }

    /// The code span a part starts with, and what follows it, e.g. `` `a.md` lines 3–4 `` → (`a.md`, `lines 3–4`).
    fileprivate static func leadingCodeSpan(_ text: String) -> (span: String, rest: String)? {
        guard text.hasPrefix("`") else { return nil }
        let afterOpen = text.dropFirst()
        guard let close = afterOpen.firstIndex(of: "`"), close != afterOpen.startIndex else { return nil }
        let rest = String(afterOpen[afterOpen.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        return (String(afterOpen[..<close]), rest)
    }

    /// The ranges a `line N` / `lines A–B, C, D–E` text states; nil when it is malformed.
    fileprivate static func parseLineList(_ text: String) -> [LineRange]? {
        let list: Substring
        if text.hasPrefix("lines") {
            list = text.dropFirst(5)
        } else if text.hasPrefix("line") {
            list = text.dropFirst(4)
        } else {
            return nil
        }
        guard list.first?.isWhitespace == true else { return nil }
        var ranges: [LineRange] = []
        for item in list.split(separator: ",", omittingEmptySubsequences: false) {
            guard let range = parseLineItem(item.trimmingCharacters(in: .whitespaces)) else { return nil }
            ranges.append(range)
        }
        return ranges
    }

    private static let dashes: Set<Character> = ["–", "-", "—"]

    private static func parseLineItem(_ item: String) -> LineRange? {
        guard let dash = item.firstIndex(where: { dashes.contains($0) }) else {
            return number(item).map { LineRange(start: $0, end: $0) }
        }
        let lower = item[..<dash].trimmingCharacters(in: .whitespaces)
        let upper = item[item.index(after: dash)...].trimmingCharacters(in: .whitespaces)
        guard let start = number(lower), let end = number(upper) else { return nil }
        return LineRange(start: start, end: end)
    }

    /// Plain ASCII digits only.
    private static func number(_ text: String) -> Int? {
        guard !text.isEmpty, text.allSatisfy({ $0 >= "0" && $0 <= "9" }) else { return nil }
        return Int(text)
    }
}

/// The parts of a `Contract:` line gathered one by one, refusing a repeat.
private struct ReferenceAccumulator {
    let repository: String
    var paths: [String] = []
    var ranges: [String: [LineRange]] = [:]
    var symbol: String?
    var commit: String?
    var sawSymbol = false
    var sawCommit = false

    init(repository: String) {
        self.repository = repository
    }

    /// Takes one part into the reference; the failure when it cannot be.
    mutating func absorb(_ part: String) -> ReferenceParseFailure? {
        if part.hasPrefix("symbol ") { return absorbSymbol(part) }
        if part.hasPrefix("commit ") { return absorbCommit(part) }
        if part.hasPrefix("Operator-supplied") { return nil }
        if part.hasPrefix("`") { return absorbPath(part) }
        return ReferenceParseFailure("the part `\(part)` is not a path, symbol or commit")
    }

    private mutating func absorbSymbol(_ part: String) -> ReferenceParseFailure? {
        guard !sawSymbol else { return ReferenceParseFailure("it names more than one symbol") }
        guard let value = CardManagedBlockParser.valueSpan(of: part, keyword: "symbol") else {
            return ReferenceParseFailure("the symbol part `\(part)` should be symbol `<name>`")
        }
        sawSymbol = true
        symbol = value
        return nil
    }

    private mutating func absorbCommit(_ part: String) -> ReferenceParseFailure? {
        guard !sawCommit else { return ReferenceParseFailure("it names more than one commit") }
        guard let value = CardManagedBlockParser.valueSpan(of: part, keyword: "commit") else {
            return ReferenceParseFailure("the commit part `\(part)` should be commit `<sha>`")
        }
        sawCommit = true
        commit = value == TranscriptionBlockLine.noCommit ? nil : value
        return nil
    }

    private mutating func absorbPath(_ part: String) -> ReferenceParseFailure? {
        guard let (path, rest) = CardManagedBlockParser.pathAndLines(of: part) else {
            return ReferenceParseFailure("the path part `\(part)` is malformed")
        }
        guard !paths.contains(path) else { return ReferenceParseFailure("it names the path `\(path)` twice") }
        paths.append(path)
        if rest.isEmpty { return nil }
        guard let parsed = CardManagedBlockParser.parseLineList(rest) else {
            return ReferenceParseFailure("the lines `\(rest)` after `\(path)` are malformed")
        }
        ranges[path] = parsed
        return nil
    }

    func finish() -> Result<TranscriptionReference, ReferenceParseFailure> {
        guard !paths.isEmpty else { return .failure(ReferenceParseFailure("it names no path")) }
        return .success(TranscriptionReference(
            repository: repository, paths: paths, ranges: ranges, symbol: symbol, commit: commit
        ))
    }
}

extension CardManagedBlockParser {
    /// The value of a `<keyword> `<value>`` part; nil when it is not exactly that.
    fileprivate static func valueSpan(of part: String, keyword: String) -> String? {
        codeSpan(String(part.dropFirst(keyword.count)).trimmingCharacters(in: .whitespaces))
    }

    fileprivate static func pathAndLines(of part: String) -> (path: String, rest: String)? {
        leadingCodeSpan(part).map { ($0.span, $0.rest) }
    }
}
