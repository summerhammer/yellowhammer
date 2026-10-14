import Domain
import Foundation
import GRDB

/// A Transcription Block row from the `transcription_block` table.
///
/// `paths` is stored joined by `\n` in the `paths` column — a Transcription Block's paths are
/// repository-relative file paths, which never contain a newline, so this is an unambiguous, simple
/// encoding that needs no JSON dependency in the Journal module. `ranges` is stored the same way: one
/// ``LineRange/token(for:)`` per path, aligned with `paths`, or `''` when no path has any.
public struct TranscriptionBlockRecord: Equatable, Sendable {
    public let id: Int64
    public let cardID: Int64
    public let repository: String
    public let paths: [String]
    public let ranges: [String: [LineRange]]
    public let symbol: String?
    public let mainlineCommit: String?
    /// The transcribed lines; nil exactly when the row is unread (an Operator-edited reference not yet
    /// read from local mainline).
    public let content: String?
    public let contentHash: String?
    public let authorSupplied: Bool
    public let authorSuppliedNightID: Int64?
    /// The Night `authorSuppliedNightID` names, joined from `night`; nil when no Night is recorded.
    public let authorSuppliedNight: NightStart?
    /// The Operator's edited `Contract:` line as read from the board, for an unread row; nil for a read
    /// row, or an edited reference that came from a legacy stamp with no line.
    public let referenceText: String?

    public init(
        id: Int64,
        cardID: Int64,
        repository: String,
        paths: [String],
        ranges: [String: [LineRange]] = [:],
        symbol: String?,
        mainlineCommit: String?,
        content: String?,
        contentHash: String?,
        authorSupplied: Bool,
        authorSuppliedNightID: Int64?,
        authorSuppliedNight: NightStart? = nil,
        referenceText: String? = nil
    ) {
        self.id = id
        self.cardID = cardID
        self.repository = repository
        self.paths = paths
        self.ranges = ranges
        self.symbol = symbol
        self.mainlineCommit = mainlineCommit
        self.content = content
        self.contentHash = contentHash
        self.authorSupplied = authorSupplied
        self.authorSuppliedNightID = authorSuppliedNightID
        self.authorSuppliedNight = authorSuppliedNight
        self.referenceText = referenceText
    }

    /// True once the lines have been read: unread <=> `content IS NULL`.
    public var isRead: Bool { content != nil }

    /// The Domain `TranscriptionBlock` this row carries. An unread row has `content` and `contentHash`
    /// `""`, and its `editedReference` is the Operator's line (`referenceText`).
    public var block: TranscriptionBlock {
        TranscriptionBlock(
            repository: repository,
            paths: paths,
            ranges: ranges,
            symbol: symbol,
            mainlineCommit: mainlineCommit,
            content: content ?? "",
            contentHash: contentHash ?? "",
            authorSupplied: authorSupplied,
            authorSuppliedNight: authorSuppliedNight,
            editedReference: content == nil ? referenceText : nil
        )
    }
}

/// The fields one Transcription Block row needs, bundled so ``JournalStore/insertTranscriptionBlock(_:cardID:_:)``
/// stays under the parameter-count limit — shared by ``JournalStore/recordTranscriptionBlocks(cardID:_:)``
/// (from a Domain `TranscriptionBlock`), ``JournalStore/replaceTranscriptionBlocks(cardID:_:)`` and
/// `finaliseAuthoring` (from a plan's `PlannedTranscription`, roadmap P9.6), which carry different sets of
/// fields. An unread row has nil `content` and `contentHash`.
public struct NewTranscriptionBlock: Sendable {
    public let repository: String
    public let paths: [String]
    public let ranges: [String: [LineRange]]
    public let symbol: String?
    public let mainlineCommit: String?
    public let content: String?
    public let contentHash: String?
    public let authorSupplied: Bool
    public let authorSuppliedNightID: Int64?
    public let referenceText: String?

    public init(
        repository: String,
        paths: [String],
        ranges: [String: [LineRange]],
        symbol: String?,
        mainlineCommit: String?,
        content: String?,
        contentHash: String?,
        authorSupplied: Bool,
        authorSuppliedNightID: Int64? = nil,
        referenceText: String? = nil
    ) {
        self.repository = repository
        self.paths = paths
        self.ranges = ranges
        self.symbol = symbol
        self.mainlineCommit = mainlineCommit
        self.content = content
        self.contentHash = contentHash
        self.authorSupplied = authorSupplied
        self.authorSuppliedNightID = authorSuppliedNightID
        self.referenceText = referenceText
    }
}

extension JournalStore {
    /// A Card's Transcription Blocks, ordered by id (authored order).
    public func transcriptionBlocks(cardID: Int64) throws -> [TranscriptionBlockRecord] {
        try read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT transcription_block.*, night.night_start AS author_supplied_night_start
                FROM transcription_block
                LEFT JOIN night ON night.id = transcription_block.author_supplied_night_id
                WHERE transcription_block.card_id = ?
                ORDER BY transcription_block.id ASC
                """,
                arguments: [cardID]
            )
            return rows.map(Self.transcriptionBlockRecord(from:))
        }
    }

    /// Replaces a Card's Transcription Blocks with `blocks`, in one transaction: delete-then-insert, in
    /// the order given (authored order). For authoring and maintenance callers holding Domain blocks.
    public func recordTranscriptionBlocks(cardID: Int64, _ blocks: [TranscriptionBlock]) throws {
        try write { db in
            try db.execute(sql: "DELETE FROM transcription_block WHERE card_id = ?", arguments: [cardID])
            for block in blocks {
                try Self.insertTranscriptionBlock(db, cardID: cardID, NewTranscriptionBlock(
                    repository: block.repository, paths: block.paths, ranges: block.ranges, symbol: block.symbol,
                    mainlineCommit: block.mainlineCommit, content: block.content, contentHash: block.contentHash,
                    authorSupplied: block.authorSupplied
                ))
            }
        }
    }

    /// Replaces a Card's Transcription Blocks with `blocks`, in one transaction: delete-then-insert, in
    /// the order given. Unlike ``recordTranscriptionBlocks(cardID:_:)`` it can write unread rows (nil
    /// `content`) and the Night an Operator's edit was seen.
    public func replaceTranscriptionBlocks(cardID: Int64, _ blocks: [NewTranscriptionBlock]) throws {
        try write { db in
            try db.execute(sql: "DELETE FROM transcription_block WHERE card_id = ?", arguments: [cardID])
            for block in blocks {
                try Self.insertTranscriptionBlock(db, cardID: cardID, block)
            }
        }
    }

    /// Records the read of an unread (Operator-edited) reference: the commit the lines were read at, the
    /// ranges actually transcribed, the lines and their hash. Clears `reference_text`. Leaves
    /// `author_supplied` and `author_supplied_night_id` alone — the label survives the read.
    public func recordTranscriptionRead(
        id: Int64, mainlineCommit: String, ranges: [String: [LineRange]], content: String, contentHash: String
    ) throws {
        try write { db in
            guard let pathsRaw = try String.fetchOne(
                db, sql: "SELECT paths FROM transcription_block WHERE id = ?", arguments: [id]
            ) else { return }
            let paths = pathsRaw.isEmpty ? [] : pathsRaw.split(separator: "\n").map(String.init)
            try db.execute(
                sql: """
                UPDATE transcription_block
                SET mainline_commit = ?, ranges = ?, content = ?, content_hash = ?, reference_text = NULL
                WHERE id = ?
                """,
                arguments: [
                    mainlineCommit, (LineRange.tokens(for: ranges, paths: paths) ?? []).joined(separator: "\n"),
                    content, contentHash, id
                ]
            )
        }
    }

    /// Inserts one Transcription Block row. Shared with ``finaliseAuthoring(_:runID:act:nightID:now:)``
    /// (roadmap P9.6) so a newly authored Card's blocks are written in the same transaction as its
    /// Feature, Cycle and Card rows, without duplicating the SQL.
    static func insertTranscriptionBlock(_ db: Database, cardID: Int64, _ block: NewTranscriptionBlock) throws {
        try db.execute(
            sql: """
            INSERT INTO transcription_block (
                card_id, repository, paths, ranges, symbol, mainline_commit, content, content_hash,
                author_supplied, author_supplied_night_id, reference_text
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                cardID, block.repository, block.paths.joined(separator: "\n"),
                (LineRange.tokens(for: block.ranges, paths: block.paths) ?? []).joined(separator: "\n"),
                block.symbol, block.mainlineCommit, block.content, block.contentHash, block.authorSupplied ? 1 : 0,
                block.authorSuppliedNightID, block.referenceText
            ]
        )
    }

    private static func transcriptionBlockRecord(from row: Row) -> TranscriptionBlockRecord {
        let pathsRaw: String = row["paths"]
        let paths = pathsRaw.isEmpty ? [] : pathsRaw.split(separator: "\n").map(String.init)
        let rangesRaw: String = row["ranges"]
        let tokens = rangesRaw.isEmpty
            ? nil : rangesRaw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return TranscriptionBlockRecord(
            id: row["id"],
            cardID: row["card_id"],
            repository: row["repository"],
            paths: paths,
            ranges: LineRange.ranges(fromTokens: tokens, paths: paths) ?? [:],
            symbol: row["symbol"],
            mainlineCommit: row["mainline_commit"],
            content: row["content"],
            contentHash: row["content_hash"],
            authorSupplied: ((row["author_supplied"] as Int?) ?? 0) != 0,
            authorSuppliedNightID: row["author_supplied_night_id"],
            authorSuppliedNight: (row["author_supplied_night_start"] as String?).flatMap(NightStart.init(rawValue:)),
            referenceText: row["reference_text"]
        )
    }
}
