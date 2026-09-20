import Foundation

/// Line indices inside a Transcription Block's interior (roadmap P9.6, P9.10): the start marker line,
/// its content and its end marker line. Shared by ``CardManagedBlockParser`` (which reads a Card's
/// Managed Block, and must never read a transcribed heading or clause line as its own) and
/// ``ManagedBlockFence`` (which counts occurrences of the Managed Block's own delimiters, and must never
/// count one that a transcribed contract happens to quote).
enum TranscriptionBlockMasking {
    private static let startPrefix = TranscriptionBlockLine.startPrefix
    private static let endMarker = TranscriptionBlockLine.endMarker

    /// `lines` is `description.components(separatedBy: "\n")` (or a block's own lines). When
    /// `requireTermination` is `false` (``CardManagedBlockParser``'s use), an unterminated start line
    /// still masks everything after it to the end of the text — the existing, pre-P9.10 behaviour, kept
    /// so the parser's reads are unchanged. When `true` (``ManagedBlockFence``'s use), an unterminated
    /// start line masks nothing at all: it must never swallow the real Managed Block end delimiter.
    static func maskedLineIndices(_ lines: [String], requireTermination: Bool = false) -> Set<Int> {
        var masked = Set<Int>()
        var index = 0
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(startPrefix), trimmed.hasSuffix("-->") else {
                index += 1
                continue
            }
            var block = Set<Int>()
            block.insert(index)
            var cursor = index + 1
            while cursor < lines.count, lines[cursor].trimmingCharacters(in: .whitespaces) != endMarker {
                block.insert(cursor)
                cursor += 1
            }
            let terminated = cursor < lines.count
            if terminated {
                block.insert(cursor)
                cursor += 1
            }
            if terminated || !requireTermination {
                masked.formUnion(block)
            }
            index = cursor
        }
        return masked
    }
}
