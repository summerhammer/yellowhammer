import Foundation

/// The Brief's prose is opaque Markdown. A deterministic, collision-free delimiter keeps quoted
/// Yellowhammer markers and headings from becoming structures during readback.
enum ArchitecturalBriefProseRegion {
    static let heading = "### Architectural Brief"
    static let startPrefix = "<!-- yh:brief-prose:start id="

    struct Region {
        let content: Range<Int>
        let masked: Range<Int>
        let malformed: Bool
    }

    static func render(_ prose: String) -> [String] {
        var identifier = 0
        while prose.contains(start(identifier)) || prose.contains(end(identifier)) {
            identifier += 1
        }
        return [start(identifier), prose, end(identifier)]
    }

    private static func start(_ identifier: Int) -> String { "\(startPrefix)\(identifier) -->" }
    private static func end(_ identifier: Int) -> String { "<!-- yh:brief-prose:end id=\(identifier) -->" }

    static func read(_ lines: [String], headingBefore: Int? = nil) -> Region? {
        // Transcribed stories can themselves contain a Brief heading.
        let transcriptions = TranscriptionBlockMasking.maskedLineIndices(lines)
        guard let headingIndex = lines.indices.first(where: {
            $0 < (headingBefore ?? lines.count) && !transcriptions.contains($0)
                && lines[$0].trimmingCharacters(in: .whitespaces) == heading
        }) else { return nil }
        let first = lines.indices.dropFirst(headingIndex + 1).first(where: {
            !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty
        }) ?? lines.count
        guard first < lines.count else {
            return Region(content: first..<first, masked: first..<first, malformed: false)
        }
        let marker = lines[first].trimmingCharacters(in: .whitespaces)
        if marker.hasPrefix(startPrefix) {
            let rawID = marker.dropFirst(startPrefix.count).dropLast(4)
            guard let identifier = Int(rawID), identifier >= 0, marker == start(identifier),
                  let last = lines.indices.dropFirst(first + 1).first(where: {
                      lines[$0].trimmingCharacters(in: .whitespaces) == end(identifier)
                  }) else {
                return Region(content: first..<lines.count, masked: first..<lines.count, malformed: true)
            }
            let boundary = lines.indices.dropFirst(last + 1).first(where: {
                lines[$0].contains(ManagedBlockFence.end)
            }) ?? lines.count
            let delimiterCount = lines[first..<boundary].filter {
                let line = $0.trimmingCharacters(in: .whitespaces)
                return line == start(identifier) || line == end(identifier)
            }.count
            guard delimiterCount == 2 else {
                return Region(content: first..<lines.count, masked: first..<lines.count, malformed: true)
            }
            return Region(content: (first + 1)..<last, masked: first..<(last + 1), malformed: false)
        }
        let endOfBlock = lines.indices.dropFirst(first).first(where: {
            !transcriptions.contains($0) && lines[$0].contains(ManagedBlockFence.end)
        }) ?? lines.count
        if lines[first..<endOfBlock].contains(where: { $0.hasPrefix("<!-- yh:brief-prose:") }) {
            return Region(content: first..<lines.count, masked: first..<lines.count, malformed: true)
        }
        // Legacy cards have no prose delimiter. Only known structural sections end their Brief;
        // an Operator's nested heading is prose. Their next rewrite installs the explicit region.
        let last = lines.indices.dropFirst(first).first(where: {
            let line = lines[$0].trimmingCharacters(in: .whitespaces)
            return line.hasPrefix(TranscriptionBlockLine.startPrefix)
                || ["### Definition of Done", "### Attempts", "### Adoption not completed"].contains(line)
                || line == CardManagedBlock.footer || line == ManagedBlockFence.end
        }) ?? lines.count
        return Region(content: first..<last, masked: first..<last, malformed: false)
    }

    static func maskedLineIndices(_ lines: [String]) -> Set<Int> {
        Set(read(lines)?.masked ?? 0..<0)
    }

    static func structureMasks(_ lines: [String], requireTermination: Bool = false) -> Set<Int> {
        let prose = maskedLineIndices(lines)
        // A fake transcription start in prose must not swallow the real following sections.
        let structuralLines = lines.enumerated().map { prose.contains($0.offset) ? "" : $0.element }
        return prose.union(TranscriptionBlockMasking.maskedLineIndices(
            structuralLines, requireTermination: requireTermination
        ))
    }
}
