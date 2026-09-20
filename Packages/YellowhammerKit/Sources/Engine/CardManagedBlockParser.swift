import Domain
import Foundation

/// A Transcription Block as read back from the board's copy of a Card's Managed Block: the renderer's
/// `<!-- yh:transcription:start ... -->` / `<!-- yh:transcription:end -->` pair and everything between.
public struct ParsedTranscription: Equatable, Sendable {
    public var repository: String
    public var paths: [String]
    public var symbol: String?
    /// The raw `commit=` field, exactly as the renderer wrote it: a commit sha, or
    /// `Operator-supplied` / `Operator-supplied as of <night>` when the block is Operator-supplied.
    public var commitField: String
    /// The `hash=` field the renderer stamped when this block was last posted.
    public var recordedHash: String
    public var content: String

    public var contentHash: String { ManagedBlockFence.sha256(content) }

    public init(
        repository: String, paths: [String], symbol: String?, commitField: String, recordedHash: String, content: String
    ) {
        self.repository = repository
        self.paths = paths
        self.symbol = symbol
        self.commitField = commitField
        self.recordedHash = recordedHash
        self.content = content
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

/// Everything ``CardManagedBlockParser`` recovers from a rendered Managed Block's text.
public struct ParsedCardBlock: Equatable, Sendable {
    public var briefProse: String?
    public var transcriptions: [ParsedTranscription]
    public var clauses: [ParsedClause]
    /// The board's copy of the Card's declared scope: nil when no `**Scope:**` line was found, and
    /// `[]` when it read `_none declared_`.
    public var scope: [String]?

    public init(
        briefProse: String?, transcriptions: [ParsedTranscription], clauses: [ParsedClause],
        scope: [String]? = nil
    ) {
        self.briefProse = briefProse
        self.transcriptions = transcriptions
        self.clauses = clauses
        self.scope = scope
    }
}

/// Parses the text ``CardManagedBlock/render()`` produces, round-tripping the Architectural Brief's
/// prose, its Transcription Blocks and the Definition of Done's clause lines.
public enum CardManagedBlockParser {
    private static let transcriptionStartPrefix = TranscriptionBlockLine.startPrefix
    private static let transcriptionEnd = TranscriptionBlockLine.endMarker
    private static let briefHeading = "### Architectural Brief"
    private static let dodHeading = "### Definition of Done"
    private static let noClausesLine = "_No clauses authored._"

    public static func parse(block: String) -> ParsedCardBlock {
        let lines = block.components(separatedBy: "\n")
        let briefProse = parseBriefProse(lines: lines)
        let transcriptions = parseTranscriptions(lines: lines)
        let clauses = parseClauses(lines: lines)
        let scope = parseScope(lines: lines)
        return ParsedCardBlock(briefProse: briefProse, transcriptions: transcriptions, clauses: clauses, scope: scope)
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
        guard let headingIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == briefHeading })
        else {
            return nil
        }
        var proseLines: [String] = []
        var index = headingIndex + 1
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(transcriptionStartPrefix) || trimmed.hasPrefix("### ") {
                break
            }
            proseLines.append(line)
            index += 1
        }
        let prose = proseLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
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
            let fields = parseTranscriptionFields(trimmed)
            var contentLines: [String] = []
            index += 1
            while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces) != transcriptionEnd {
                contentLines.append(lines[index])
                index += 1
            }
            // index now at the end marker (or past the end of the text if malformed); skip it.
            if index < lines.count { index += 1 }

            let pathsRaw = fields["paths"] ?? ""
            let paths = pathsRaw.isEmpty ? [] : pathsRaw.split(separator: ",").map(String.init)
            let symbolRaw = fields["symbol"]
            let symbol = (symbolRaw == nil || symbolRaw == "-") ? nil : symbolRaw

            results.append(ParsedTranscription(
                repository: fields["repo"] ?? "",
                paths: paths,
                symbol: symbol,
                commitField: fields["commit"] ?? "",
                recordedHash: fields["hash"] ?? "",
                content: contentLines.joined(separator: "\n")
            ))
        }
        return results
    }

    /// Parses `key=value` pairs from a transcription start comment. The `commit=` field's value may
    /// itself contain spaces (`Operator-supplied as of 2026-09-17`), so it — and only it — is read up
    /// to the next known key, rather than split naively on whitespace.
    private static func parseTranscriptionFields(_ comment: String) -> [String: String] {
        var text = comment
        if text.hasPrefix(transcriptionStartPrefix) {
            text.removeFirst(transcriptionStartPrefix.count)
        }
        if text.hasSuffix("-->") {
            text.removeLast(3)
        }
        text = text.trimmingCharacters(in: .whitespaces)

        let knownKeys = ["repo=", "paths=", "symbol=", "commit=", "hash="]
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

    /// Every line index that sits inside a Transcription Block (its start marker, its content and its
    /// end marker): a transcription of a specification story is markdown of its own, and may contain a
    /// `### ` heading or a `- [ ]` line that must never be read as this document's own (roadmap P9.6).
    /// Delegates to ``TranscriptionBlockMasking``, shared with ``ManagedBlockFence`` (roadmap P9.10).
    private static func maskedLineIndices(_ lines: [String]) -> Set<Int> {
        TranscriptionBlockMasking.maskedLineIndices(lines)
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
