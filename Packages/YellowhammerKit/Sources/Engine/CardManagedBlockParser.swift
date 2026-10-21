import Domain
import Foundation

/// A Transcription Block's REFERENCE as read back from the board's copy of a Card's Managed Block
/// (spec: feature-authoring/author-an-architectural-brief#edited-reference). The visible `Contract:` line
/// between the delimiters is the reference — an Operator may have edited it — and it wins over the
/// `<!-- yh:transcription:start ... -->` stamp, which is only the machine's mirror. A card with no such
/// line (one written before the Card showed a reference only) is read from its stamp.
public struct ParsedTranscription: Equatable, Sendable {
    public var repository: String
    public var paths: [String]
    /// The line ranges per path, as written (not unioned or validated); `[:]` for none.
    public var ranges: [String: [LineRange]]
    public var symbol: String?
    /// The commit named; nil when the reference names none (`-`).
    public var commit: String?
    /// The raw visible `Contract:` line, trimmed, when the block's interior had one.
    public var line: String?
    /// Why the reference could not be parsed; when non-nil the field values above are meaningless.
    public var failure: String?

    public init(
        repository: String, paths: [String], ranges: [String: [LineRange]] = [:], symbol: String? = nil,
        commit: String? = nil, line: String? = nil, failure: String? = nil
    ) {
        self.repository = repository
        self.paths = paths
        self.ranges = ranges
        self.symbol = symbol
        self.commit = commit
        self.line = line
        self.failure = failure
    }
}

/// A Definition of Done line as read back from the board, tagged or not.
public struct ParsedClause: Equatable, Sendable {
    public var cid: String?
    public var text: String
    public var citation: String?

    public init(cid: String?, text: String, citation: String?) {
        self.cid = cid
        self.text = text
        self.citation = citation
    }
}

/// Input inside a Managed Block that a human edited into something Yellowhammer cannot read as the field it
/// sits in. It is retained on the board exactly as written and never imported: importing what could be read
/// of it would drop the rest (spec: board-projection / maintain-the-managed-block, field ownership).
public struct InvalidBlockInput: Equatable, Sendable {
    /// The supported input field: `scope` or `definition of done`.
    public var field: String
    public var reason: String

    public init(field: String, reason: String) {
        self.field = field
        self.reason = reason
    }
}

/// Everything ``CardManagedBlockParser`` recovers from a rendered Managed Block's text.
public struct ParsedCardBlock: Equatable, Sendable {
    public var briefProse: String?
    public var transcriptions: [ParsedTranscription]
    public var clauses: [ParsedClause]
    /// The board's copy of the Card's declared scope: nil when no `**Scope:**` line was found, and
    /// `[]` when it read `_none declared_`.
    public var scope: [String]?
    /// The `Card override:` lines the block's header holds, exactly as written and in order: none when the
    /// line was removed, two when it was duplicated. Not judged here — ``CardOverrideField/reading(of:)``
    /// does that, and a malformed value is imported and retained all the same.
    public var cardOverrideLines: [String]
    /// The supported input fields whose text could not be read; see ``InvalidBlockInput``.
    public var invalid: [InvalidBlockInput]
    /// Whether the block has a `### Definition of Done` section at all. Without one `clauses` is empty
    /// because nothing was read, which is not the same as the Operator emptying the list.
    public var hasDefinitionOfDoneSection: Bool

    public init(
        briefProse: String?, transcriptions: [ParsedTranscription], clauses: [ParsedClause],
        scope: [String]? = nil, cardOverrideLines: [String] = [], invalid: [InvalidBlockInput] = [],
        hasDefinitionOfDoneSection: Bool = true
    ) {
        self.cardOverrideLines = cardOverrideLines
        self.hasDefinitionOfDoneSection = hasDefinitionOfDoneSection
        self.briefProse = briefProse
        self.transcriptions = transcriptions
        self.clauses = clauses
        self.scope = scope
        self.invalid = invalid
    }

    /// The field's name, when ``invalid`` names it.
    public func isInvalid(_ field: String) -> Bool { invalid.contains { $0.field == field } }
}

/// Parses the text ``CardManagedBlock/render()`` produces, round-tripping the Architectural Brief's
/// prose, its Transcription Blocks and the Definition of Done's clause lines.
public enum CardManagedBlockParser {
    private static let transcriptionStartPrefix = TranscriptionBlockLine.startPrefix
    private static let transcriptionEnd = TranscriptionBlockLine.endMarker
    private static let dodHeading = "### Definition of Done"
    private static let noClausesLine = "_No clauses authored._"

    public static func parse(block: String) -> ParsedCardBlock {
        let lines = block.components(separatedBy: "\n")
        let briefProse = parseBriefProse(lines: lines)
        let proseMask = ArchitecturalBriefProseRegion.maskedLineIndices(lines)
        let structuralLines = lines.enumerated().map { proseMask.contains($0.offset) ? "" : $0.element }
        let transcriptions = parseTranscriptions(lines: structuralLines)
        let clauses = parseClauses(lines: lines)
        let scope = parseScope(lines: structuralLines)
        var invalid: [InvalidBlockInput] = []
        if let scope, scope.contains(where: \.isEmpty) {
            invalid.append(InvalidBlockInput(
                field: "scope", reason: "the `**Scope:**` line has an empty path; list paths separated by commas"
            ))
        }
        let unreadable = unreadableClauseLines(lines: lines)
        if !unreadable.isEmpty {
            invalid.append(InvalidBlockInput(
                field: "definition of done",
                reason: "\(unreadable.count) line(s) under `### Definition of Done` are not clause lines "
                    + "(`- [ ] text (citation)`): \(unreadable.map { "`\($0)`" }.joined(separator: ", "))"
            ))
        }
        let masked = maskedLineIndices(lines)
        let hasSection = lines.indices.contains {
            !masked.contains($0) && lines[$0].trimmingCharacters(in: .whitespaces) == dodHeading
        }
        return ParsedCardBlock(
            briefProse: briefProse, transcriptions: transcriptions, clauses: clauses, scope: scope,
            cardOverrideLines: parseCardOverrideLines(lines: lines), invalid: invalid,
            hasDefinitionOfDoneSection: hasSection
        )
    }

    // MARK: - Card override

    /// The `Card override:` lines of the block's header: its top-level lines before the first `### ` heading,
    /// outside fenced code. The Architectural Brief, the Definition of Done and the Attempts history all sit
    /// under a heading, so a route-like string in prose, a quoted reviewer request or a transcription is
    /// never read as the field.
    private static func parseCardOverrideLines(lines: [String]) -> [String] {
        var found: [String] = []
        var fence: String?
        for line in lines {
            if line.hasPrefix("### ") && fence == nil { break }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let marker = ["```", "~~~"].first(where: { trimmed.hasPrefix($0) }) {
                if fence == nil {
                    fence = marker
                } else if fence == marker {
                    fence = nil
                }
                continue
            }
            if fence == nil, CardOverrideField.isFieldLine(line) { found.append(line) }
        }
        return found
    }

    // MARK: - Scope

    private static let scopeNoneLine = "**Scope:** _none declared_"
    private static let scopePrefix = "**Scope:** "

    private static func parseScope(lines: [String]) -> [String]? {
        guard let line = lines.first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix(scopePrefix) })
        else {
            return nil
        }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed == scopeNoneLine {
            return []
        }
        let rest = trimmed.dropFirst(scopePrefix.count)
        return rest.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "`"))
        }
    }

    // MARK: - Brief prose

    private static func parseBriefProse(lines: [String]) -> String? {
        guard let region = ArchitecturalBriefProseRegion.read(lines), !region.malformed else { return nil }
        let prose = lines[region.content].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return prose.isEmpty ? nil : prose
    }

    // MARK: - Transcriptions

    private static func parseTranscriptions(lines: [String]) -> [ParsedTranscription] {
        var results: [ParsedTranscription] = []
        var index = 0
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(transcriptionStartPrefix), trimmed.hasSuffix("-->") else {
                index += 1
                continue
            }
            let stamp = trimmed
            // Everything up to the end marker is interior; the first `Contract:` line in it is the reference.
            index += 1
            var contractLine: String?
            while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces) != transcriptionEnd {
                let interior = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
                if contractLine == nil, interior.hasPrefix(referencePrefix) { contractLine = interior }
                index += 1
            }
            // index now at the end marker (or past the end of the text if malformed); skip it.
            if index < lines.count { index += 1 }

            results.append(contractLine.map(parsedFromLine) ?? parsedFromStamp(stamp))
        }
        return results
    }

    private static func parsedFromLine(_ line: String) -> ParsedTranscription {
        switch parseReference(line: line) {
        case .success(let reference):
            return ParsedTranscription(
                repository: reference.repository, paths: reference.paths, ranges: reference.ranges,
                symbol: reference.symbol, commit: reference.commit, line: line
            )
        case .failure(let failure):
            return ParsedTranscription(repository: "", paths: [], line: line, failure: failure.reason)
        }
    }

    /// The reference a block states in its stamp alone, when its visible `Contract:` line is gone. A
    /// `commit=` of `-` names no commit.
    private static func parsedFromStamp(_ stamp: String) -> ParsedTranscription {
        let fields = parseTranscriptionFields(stamp)
        let pathsRaw = fields["paths"] ?? ""
        let paths = pathsRaw.isEmpty ? [] : pathsRaw.split(separator: ",").map(String.init)
        let symbolRaw = fields["symbol"]
        let symbol = (symbolRaw == nil || symbolRaw == "-") ? nil : symbolRaw
        let tokens = fields["ranges"].map {
            $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        }
        guard let ranges = LineRange.ranges(fromTokens: tokens, paths: paths) else {
            return ParsedTranscription(
                repository: "", paths: [], failure: "the stamp's `ranges=` field is malformed"
            )
        }
        let commitRaw = fields["commit"] ?? ""
        let commit = (commitRaw.isEmpty || commitRaw == TranscriptionBlockLine.noCommit) ? nil : commitRaw
        return ParsedTranscription(
            repository: fields["repo"] ?? "", paths: paths, ranges: ranges, symbol: symbol, commit: commit
        )
    }

    /// Parses `key=value` pairs from a transcription start comment. A value runs up to the next known
    /// key, so a path or symbol with a space in it is not split naively on whitespace.
    private static func parseTranscriptionFields(_ comment: String) -> [String: String] {
        var text = comment
        if text.hasPrefix(transcriptionStartPrefix) {
            text.removeFirst(transcriptionStartPrefix.count)
        }
        if text.hasSuffix("-->") {
            text.removeLast(3)
        }
        text = text.trimmingCharacters(in: .whitespaces)

        let knownKeys = ["repo=", "paths=", "ranges=", "symbol=", "commit="]
        var fields: [String: String] = [:]
        var remaining = Substring(text)
        while !remaining.isEmpty {
            remaining = Substring(remaining.trimmingCharacters(in: .whitespaces))
            guard let key = knownKeys.first(where: { remaining.hasPrefix($0) }) else { break }
            remaining.removeFirst(key.count)
            // Value runs until the start of the next known key, or end of string.
            var endIndex = remaining.endIndex
            for otherKey in knownKeys {
                if let range = remaining.range(of: " \(otherKey)") {
                    if range.lowerBound < endIndex { endIndex = range.lowerBound }
                }
            }
            let value = String(remaining[remaining.startIndex..<endIndex]).trimmingCharacters(in: .whitespaces)
            fields[String(key.dropLast())] = value
            remaining = remaining[endIndex...]
        }
        return fields
    }

    // MARK: - Clauses

    /// Every line index that sits inside opaque Brief prose or a Transcription Block (its start marker, its
    /// end marker): a transcription of a specification story is markdown of its own, and may contain a
    /// `### ` heading or a `- [ ]` line that must never be read as this document's own (roadmap P9.6).
    /// Shares the opaque-region reader with ``ManagedBlockFence``.
    private static func maskedLineIndices(_ lines: [String]) -> Set<Int> {
        ArchitecturalBriefProseRegion.structureMasks(lines)
    }

    private static func parseClauses(lines: [String]) -> [ParsedClause] {
        let masked = maskedLineIndices(lines)
        guard let headingIndex = lines.indices.first(where: {
            !masked.contains($0) && lines[$0].trimmingCharacters(in: .whitespaces) == dodHeading
        }) else {
            return []
        }
        var results: [ParsedClause] = []
        var index = headingIndex + 1
        while index < lines.count {
            if masked.contains(index) {
                index += 1
                continue
            }
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("### ") { break }
            if trimmed == noClausesLine || trimmed.isEmpty {
                index += 1
                continue
            }
            if let clause = parseClauseLine(trimmed) {
                results.append(clause)
            }
            index += 1
        }
        return results
    }

    /// The lines under the Definition of Done heading that are neither a clause nor blank nor the empty
    /// marker: text a human typed there that ``parseClauses(lines:)`` would silently drop, and the
    /// reconciliation would then read as every clause deleted.
    private static func unreadableClauseLines(lines: [String]) -> [String] {
        let masked = maskedLineIndices(lines)
        guard let headingIndex = lines.indices.first(where: {
            !masked.contains($0) && lines[$0].trimmingCharacters(in: .whitespaces) == dodHeading
        }) else {
            return []
        }
        var unreadable: [String] = []
        for index in lines.indices.dropFirst(headingIndex + 1) where !masked.contains(index) {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("### ") { break }
            if trimmed.isEmpty || trimmed == noClausesLine { continue }
            if parseClauseLine(trimmed) == nil { unreadable.append(trimmed) }
        }
        return unreadable
    }

    /// Parses one `- [ ] <!-- yh:clause:<cid> --> text (citation)` line. The `<!-- yh:clause:... -->`
    /// marker is optional (an untagged human line); the trailing `(<citation>)` is optional too.
    private static func parseClauseLine(_ line: String) -> ParsedClause? {
        var rest = line
        guard rest.hasPrefix("- [ ]") || rest.hasPrefix("- [x]") else { return nil }
        rest.removeFirst(5)
        rest = rest.trimmingCharacters(in: .whitespaces)

        var cid: String?
        let markerPrefix = "<!-- yh:clause:"
        if rest.hasPrefix(markerPrefix), let markerEnd = rest.range(of: "-->") {
            let markerContent = rest[rest.index(rest.startIndex, offsetBy: markerPrefix.count)..<markerEnd.lowerBound]
            cid = markerContent.trimmingCharacters(in: .whitespaces)
            rest = String(rest[markerEnd.upperBound...]).trimmingCharacters(in: .whitespaces)
        }

        var citation: String?
        if rest.hasSuffix(")"), let openParen = rest.range(of: "(", options: .backwards) {
            let candidate = String(rest[rest.index(after: openParen.lowerBound)..<rest.index(before: rest.endIndex)])
            citation = candidate
            rest = String(rest[rest.startIndex..<openParen.lowerBound]).trimmingCharacters(in: .whitespaces)
        }

        return ParsedClause(cid: cid, text: rest, citation: citation)
    }
}
