import Domain
import Foundation
import Journal

/// What the board's copy of one Transcription Block is, against the Journal's records.
enum TranscriptionMatch: Equatable {
    /// The board block states the reference a Journal record already holds. `symbol` is the board's when the
    /// board block parsed (a symbol-only edit is kept as written), else the record's own.
    case kept(TranscriptionBlockRecord, symbol: String?)
    /// The board block states a reference no record holds: an Operator's edit, or a block the Operator added.
    case edited(ParsedTranscription)
}

/// The outcome of matching a Card's board blocks against its Journal records.
struct TranscriptionMatching: Equatable {
    /// One entry per board block, in board order.
    let blocks: [TranscriptionMatch]
    /// The records no board block matched, in Journal order: references the Operator removed whole.
    let deletions: [TranscriptionBlockRecord]
}

/// Pairs the board's Transcription Blocks with the Journal's records by what they SAY, never by
/// position: deleting block 2 of 3 must leave blocks 1 and 3 kept, not mark 3 edited (spec:
/// feature-authoring/author-an-architectural-brief#edited-reference). Shared by Reconcile and the
/// opening inspection.
enum TranscriptionReferenceMatch {
    static func match(board: [ParsedTranscription], records: [TranscriptionBlockRecord]) -> TranscriptionMatching {
        var used = Set<Int64>()
        var blocks: [TranscriptionMatch] = []
        for parsed in board {
            if let record = records.first(where: { !used.contains($0.id) && matches(parsed, $0) }) {
                used.insert(record.id)
                blocks.append(.kept(record, symbol: parsed.failure == nil ? parsed.symbol : record.symbol))
            } else {
                blocks.append(.edited(parsed))
            }
        }
        return TranscriptionMatching(blocks: blocks, deletions: records.filter { !used.contains($0.id) })
    }

    /// Symbol never takes part: a symbol-only edit is no edit.
    private static func matches(_ parsed: ParsedTranscription, _ record: TranscriptionBlockRecord) -> Bool {
        if parsed.failure == nil, sameReference(parsed, record) { return true }
        // An unread edit, parseable or not, seen again unchanged.
        if !record.isRead, let text = record.referenceText, let line = parsed.line {
            return MarkdownEquivalence.rendersSame(line, text)
        }
        return false
    }

    private static func sameReference(_ parsed: ParsedTranscription, _ record: TranscriptionBlockRecord) -> Bool {
        parsed.repository == record.repository && parsed.paths == record.paths
            && normalised(parsed.ranges) == normalised(record.ranges)
            && sameCommit(parsed.commit, record.mainlineCommit)
    }

    /// The Journal holds the resolved full sha, so a board commit of 7 or more characters that prefixes it
    /// is the same commit.
    private static func sameCommit(_ board: String?, _ record: String?) -> Bool {
        guard let board, let record else { return board == nil && record == nil }
        return board == record || (board.count >= 7 && record.hasPrefix(board))
    }

    /// Ranges per path compared as unions when every range is well-formed (start >= 1, end >= start); as
    /// written otherwise, so a malformed range still equals itself. Empty lists are no ranges.
    private static func normalised(_ ranges: [String: [LineRange]]) -> [String: [LineRange]] {
        let nonEmpty = ranges.filter { !$0.value.isEmpty }
        let wellFormed = nonEmpty.values.allSatisfy { $0.allSatisfy { $0.start >= 1 && $0.end >= $0.start } }
        return wellFormed ? nonEmpty.mapValues(LineRange.union) : nonEmpty
    }
}
