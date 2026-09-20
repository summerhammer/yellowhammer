import Domain
import Foundation
import GRDB

/// A Transcription Block row from the `transcription_block` table.
///
/// `paths` is stored joined by `\n` in the `paths` column — a Transcription Block's paths are
/// repository-relative file paths, which never contain a newline, so this is an unambiguous, simple
/// encoding that needs no JSON dependency in the Journal module.
public struct TranscriptionBlockRecord: Equatable, Sendable {
    public let id: Int64
    public let cardID: Int64
    public let repository: String
    public let paths: [String]
    public let symbol: String?
    public let mainlineCommit: String?
    public let content: String?
    public let contentHash: String
    public let authorSupplied: Bool
    public let authorSuppliedNightID: Int64?

    public init(
        id: Int64,
        cardID: Int64,
        repository: String,
        paths: [String],
        symbol: String?,
        mainlineCommit: String?,
        content: String?,
        contentHash: String,
        authorSupplied: Bool,
        authorSuppliedNightID: Int64?
    ) {
        self.id = id
        self.cardID = cardID
        self.repository = repository
        self.paths = paths
        self.symbol = symbol
        self.mainlineCommit = mainlineCommit
        self.content = content
        self.contentHash = contentHash
        self.authorSupplied = authorSupplied
        self.authorSuppliedNightID = authorSuppliedNightID
    }

    /// The Domain `TranscriptionBlock` this row carries. `content` is `""` when the row has none
    /// recorded yet, and `authorSuppliedNight` is left nil — mapping a night id to a `NightStart` is
    /// not cheap from this row alone, and nil is an acceptable placeholder for the renderer.
    public var block: TranscriptionBlock {
        TranscriptionBlock(
            repository: repository,
            paths: paths,
            symbol: symbol,
            mainlineCommit: mainlineCommit,
            content: content ?? "",
            contentHash: contentHash,
            authorSupplied: authorSupplied,
            authorSuppliedNight: nil
        )
    }
}

/// The fields one Transcription Block row needs, bundled so ``JournalStore/insertTranscriptionBlock(_:cardID:_:)``
/// stays under the parameter-count limit — shared by ``JournalStore/recordTranscriptionBlocks(cardID:_:)``
/// (from a Domain `TranscriptionBlock`) and `finaliseAuthoring` (from a plan's `PlannedTranscription`,
/// roadmap P9.6), which carry different sets of fields.
struct NewTranscriptionBlock {
    let repository: String
    let paths: [String]
    let symbol: String?
    let mainlineCommit: String?
    let content: String
    let contentHash: String
    let authorSupplied: Bool
}

extension JournalStore {
    /// A Card's Transcription Blocks, ordered by id (authored order).
    public func transcriptionBlocks(cardID: Int64) throws -> [TranscriptionBlockRecord] {
        try read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM transcription_block WHERE card_id = ? ORDER BY id ASC",
                arguments: [cardID]
            )
            return rows.map(Self.transcriptionBlockRecord(from:))
        }
    }

    /// Replaces a Card's Transcription Blocks with `blocks`, in one transaction: delete-then-insert, in
    /// the order given, so ``transcriptionBlocks(cardID:)`` reads them back paired by position with
    /// what the brief's renderer emitted.
    public func recordTranscriptionBlocks(cardID: Int64, _ blocks: [TranscriptionBlock]) throws {
        try write { db in
            try db.execute(sql: "DELETE FROM transcription_block WHERE card_id = ?", arguments: [cardID])
            for block in blocks {
                try Self.insertTranscriptionBlock(db, cardID: cardID, NewTranscriptionBlock(
                    repository: block.repository, paths: block.paths, symbol: block.symbol,
                    mainlineCommit: block.mainlineCommit, content: block.content, contentHash: block.contentHash,
                    authorSupplied: block.authorSupplied
                ))
            }
        }
    }

    /// Inserts one Transcription Block row. Shared with ``finaliseAuthoring(_:runID:act:nightID:now:)``
    /// (roadmap P9.6) so a newly authored Card's blocks are written in the same transaction as its
    /// Feature, Cycle and Card rows, without duplicating the SQL.
    static func insertTranscriptionBlock(_ db: Database, cardID: Int64, _ block: NewTranscriptionBlock) throws {
        try db.execute(
            sql: """
            INSERT INTO transcription_block (
                card_id, repository, paths, symbol, mainline_commit, content, content_hash,
                author_supplied, author_supplied_night_id
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                cardID, block.repository, block.paths.joined(separator: "\n"), block.symbol,
                block.mainlineCommit, block.content, block.contentHash, block.authorSupplied ? 1 : 0, nil
            ]
        )
    }

    /// Voids a Transcription Block's stamp: an Operator edit inside it means the block is no longer
    /// backed by a recorded mainline commit. `author_supplied = 1`, `author_supplied_night_id = nightID`,
    /// `mainline_commit = NULL`. Permanent: nothing in this module clears it again.
    public func voidTranscriptionStamp(id: Int64, nightID: Int64?) throws {
        try write { db in
            try db.execute(
                sql: """
                UPDATE transcription_block
                SET author_supplied = 1, author_supplied_night_id = ?, mainline_commit = NULL
                WHERE id = ?
                """,
                arguments: [nightID, id]
            )
        }
    }

    /// Updates a Transcription Block's stored content and content hash — the board's copy, read back by
    /// the Readiness Check's reconciliation, replaces the Journal's.
    public func updateTranscriptionContent(id: Int64, content: String, contentHash: String) throws {
        try write { db in
            try db.execute(
                sql: "UPDATE transcription_block SET content = ?, content_hash = ? WHERE id = ?",
                arguments: [content, contentHash, id]
            )
        }
    }

    private static func transcriptionBlockRecord(from row: Row) -> TranscriptionBlockRecord {
        let pathsRaw: String = row["paths"]
        let paths = pathsRaw.isEmpty ? [] : pathsRaw.split(separator: "\n").map(String.init)
        return TranscriptionBlockRecord(
            id: row["id"],
            cardID: row["card_id"],
            repository: row["repository"],
            paths: paths,
            symbol: row["symbol"],
            mainlineCommit: row["mainline_commit"],
            content: row["content"],
            contentHash: row["content_hash"],
            authorSupplied: ((row["author_supplied"] as Int?) ?? 0) != 0,
            authorSuppliedNightID: row["author_supplied_night_id"]
        )
    }
}
