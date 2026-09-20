import Domain
import Foundation

/// The Transcription Block delimiter format (roadmap P9.6; spec: feature-authoring/
/// author-an-architectural-brief): a `<!-- yh:transcription:start ... -->` comment carrying the
/// repository, every path, the symbol (or `-`) and the mainline commit (or an Operator-supplied marker)
/// it was read at, plus a content hash — the block's content — then `<!-- yh:transcription:end -->`.
/// Shared by ``CardManagedBlock``'s renderer and the authoring transaction's initial Card descriptions
/// (``AuthoringPlanner``), so the authored text is byte-identical to what a later Managed Block rewrite
/// emits — one level down from what ``DefinitionOfDoneClauseLine`` does for clause lines.
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
        let comment = "\(startPrefix)repo=\(block.repository) paths=\(pathsStr) " +
            "symbol=\(symbolStr) commit=\(commit) hash=\(block.contentHash) -->"
        return ["", comment, block.content, endMarker]
    }
}
