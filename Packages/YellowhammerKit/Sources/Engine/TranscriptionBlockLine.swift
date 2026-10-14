import Domain
import Foundation

/// The Transcription Block delimiter format (roadmap P9.6; spec: feature-authoring/
/// author-an-architectural-brief): a `<!-- yh:transcription:start ... -->` comment carrying the
/// repository, every path, the line ranges per path (only when some path has any), the symbol (or `-`)
/// and the mainline commit it was read at (or `-` when the block has none), then a visible reference
/// line, then `<!-- yh:transcription:end -->`.
///
/// The card carries the REFERENCE only — repository, paths, ranges, symbol, commit — never the
/// transcribed lines or their hash: those live in the Journal, and the worker's instruction is built
/// from there. Shared by ``CardManagedBlock``'s renderer and the authoring transaction's initial Card
/// descriptions (``AuthoringPlanner``), so the authored text is byte-identical to what a later Managed
/// Block rewrite emits — one level down from what ``DefinitionOfDoneClauseLine`` does for clause lines.
///
/// The visible line is the reference: an Operator may edit it on the board
/// (spec: feature-authoring/author-an-architectural-brief#edited-reference), and
/// ``CardManagedBlockParser/parseReference(line:)`` reads it back. The stamp comment is only the machine's
/// delimiter and mirror. The line's grammar is a parsed contract:
///
/// ```
/// Contract: `<repo>` · `<path>`[ <lines>] · … · symbol `<symbol>` · commit `<sha>`[ · Operator-supplied, as of <YYYY-MM-DD>]
/// ```
///
/// where `<lines>` is ``LineRange/displayText(_:)`` (`line 7` / `lines 120–180, 200–210`). A path part
/// repeats per path; the symbol part appears only when there is a symbol; the commit part is always
/// there (`` commit `-` `` when the block has none); the Operator-supplied part appears only when the
/// block is `authorSupplied` (plain `Operator-supplied` when the Night is unknown).
///
/// A block whose `editedReference` is set — an Operator's edit not yet read — renders its stamp from its
/// own fields and then that text VERBATIM as the visible line, so the edit survives any rewrite exactly as
/// the Operator wrote it.
enum TranscriptionBlockLine {
    static let startPrefix = "<!-- yh:transcription:start "
    static let endMarker = "<!-- yh:transcription:end -->"

    /// The commit field's value, in the stamp and in the visible line, for a block with no commit.
    static let noCommit = "-"

    static func render(_ block: TranscriptionBlock) -> [String] {
        let pathsStr = block.paths.joined(separator: ",")
        let symbolStr = block.symbol ?? "-"
        var fields = "repo=\(block.repository) paths=\(pathsStr)"
        if let tokens = LineRange.tokens(for: block.ranges, paths: block.paths) {
            fields += " ranges=\(tokens.joined(separator: ","))"
        }
        let comment = "\(startPrefix)\(fields) symbol=\(symbolStr) commit=\(block.mainlineCommit ?? noCommit) -->"
        return ["", comment, block.editedReference ?? visibleReference(block), endMarker]
    }

    /// The one Markdown line a reader of the Card sees, per the grammar above.
    private static func visibleReference(_ block: TranscriptionBlock) -> String {
        let paths = block.paths.map { path -> String in
            guard let ranges = block.ranges[path], !ranges.isEmpty else { return "`\(path)`" }
            return "`\(path)` \(LineRange.displayText(ranges))"
        }
        var parts = ["Contract: `\(block.repository)`"] + paths
        if let symbol = block.symbol { parts.append("symbol `\(symbol)`") }
        parts.append("commit `\(block.mainlineCommit ?? noCommit)`")
        if block.authorSupplied {
            let mark = block.authorSuppliedNight.map { "Operator-supplied, as of \($0.rawValue)" }
            parts.append(mark ?? "Operator-supplied")
        }
        return parts.joined(separator: " · ")
    }
}
