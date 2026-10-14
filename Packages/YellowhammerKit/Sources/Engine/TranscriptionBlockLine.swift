import Domain
import Foundation

/// The Transcription Block delimiter format (roadmap P9.6; spec: feature-authoring/
/// author-an-architectural-brief): a `<!-- yh:transcription:start ... -->` comment carrying the
/// repository, every path, the line ranges per path (only when some path has any), the symbol (or `-`)
/// and the mainline commit (or an Operator-supplied marker) it was read at, then a visible reference
/// line, then `<!-- yh:transcription:end -->`.
///
/// The card carries the REFERENCE only — repository, paths, ranges, symbol, commit — never the
/// transcribed lines or their hash: those live in the Journal, and the worker's instruction is built
/// from there. Shared by ``CardManagedBlock``'s renderer and the authoring transaction's initial Card
/// descriptions (``AuthoringPlanner``), so the authored text is byte-identical to what a later Managed
/// Block rewrite emits — one level down from what ``DefinitionOfDoneClauseLine`` does for clause lines.
enum TranscriptionBlockLine {
    static let startPrefix = "<!-- yh:transcription:start "
    static let endMarker = "<!-- yh:transcription:end -->"

    /// Renders one block. `commitField` overrides what the block's own `mainlineCommit` /
    /// `authorSupplied` would otherwise say — ``CardManagedBlock`` needs to say
    /// "Operator-supplied as of \(night)", which a bare `TranscriptionBlock` cannot express on its own;
    /// a freshly authored block (never Operator-supplied) omits it and gets its `mainlineCommit`.
    static func render(_ block: TranscriptionBlock, commitField: String? = nil) -> [String] {
        let pathsStr = block.paths.joined(separator: ",")
        let symbolStr = block.symbol ?? "-"
        let commit = commitField ?? (block.mainlineCommit ?? "Operator-supplied")
        var fields = "repo=\(block.repository) paths=\(pathsStr)"
        if let tokens = LineRange.tokens(for: block.ranges, paths: block.paths) {
            fields += " ranges=\(tokens.joined(separator: ","))"
        }
        let comment = "\(startPrefix)\(fields) symbol=\(symbolStr) commit=\(commit) -->"
        return ["", comment, visibleReference(block, commit: commit), endMarker]
    }

    /// The one Markdown line a reader of the Card sees: ``Contract: `api` · `openapi.yaml` lines 120–180 ·
    /// symbol `ClassList` · commit `abc…` ``. Never parsed back — the comment above it is the stamp.
    private static func visibleReference(_ block: TranscriptionBlock, commit: String) -> String {
        let paths = block.paths.map { path -> String in
            guard let ranges = block.ranges[path], !ranges.isEmpty else { return "`\(path)`" }
            return "`\(path)` \(LineRange.displayText(ranges))"
        }
        var parts = ["Contract: `\(block.repository)`"] + paths
        if let symbol = block.symbol { parts.append("symbol `\(symbol)`") }
        parts.append("commit `\(commit)`")
        return parts.joined(separator: " · ")
    }
}
