import Domain
import Foundation
import Journal
import Repositories

/// What reading a Card's unread (Operator-edited) Transcription Block references found.
struct ReferenceReads {
    /// One failure per reference that could not be parsed or read: the Card is not Ready, with the reason.
    var failures: [ReadinessFailure] = []
    /// Whether any reference was read and recorded, so the Card now shows a different reference.
    var anyRead = false
}

// An Operator's edit to a Transcription Block's reference is read from local mainline at the commit it
// names, at dispatch (spec: feature-authoring/author-an-architectural-brief#edited-reference). An unread
// record stays unread in the Journal until its read succeeds, so an unreadable edit is retried at every
// evaluation without the Delta Read having to see the Card change again.
extension ReadinessCheck {
    /// Reads every unread record. Needs the Project's repositories: without them nothing can be read, and
    /// the Card is already not Ready (`.repositoriesUnconfigured`).
    func readUnreadReferences(card: CardRecord, context: BuildActContext) async throws -> ReferenceReads {
        var reads = ReferenceReads()
        guard let repositories = context.act.repositories else { return reads }
        let journal = context.act.journal
        for record in try journal.transcriptionBlocks(cardID: card.id) where !record.isRead {
            if let text = record.referenceText, case .failure(let failure) = CardManagedBlockParser.parseReference(
                line: text
            ) {
                reads.failures.append(.referenceUnreadable(
                    repository: record.repository, reference: text, reason: failure.reason
                ))
                continue
            }
            switch await references.read(record, in: repositories, mainlines: context.act.mainlines) {
            case .success(let block):
                guard let commit = block.mainlineCommit else {
                    reads.failures.append(.referenceUnreadable(
                        repository: record.repository, reference: Self.referenceText(of: record),
                        reason: "the read resolved no commit"
                    ))
                    continue
                }
                try journal.recordTranscriptionRead(
                    id: record.id, mainlineCommit: commit, ranges: block.ranges, content: block.content,
                    contentHash: block.contentHash
                )
                reads.anyRead = true
            case .failure(let failure):
                reads.failures.append(.referenceUnreadable(
                    repository: record.repository, reference: Self.referenceText(of: record),
                    reason: failure.reason
                ))
            }
        }
        return reads
    }

    /// The Operator's own line, or the fields rendered as one when the edit came from a legacy stamp.
    private static func referenceText(of record: TranscriptionBlockRecord) -> String {
        if let text = record.referenceText { return text }
        var block = record.block
        block.editedReference = nil
        block.authorSupplied = false
        return TranscriptionBlockLine.render(block)[2]
    }

    /// Rewrites the Card's Managed Block from the Journal, once. Unread blocks render their edited line
    /// verbatim. A Card with no Outbox wired has nothing to rewrite through.
    func rewriteManagedBlock(card: CardRecord, context: BuildActContext) async throws {
        guard let outbox = context.act.outbox else { return }
        let journal = context.act.journal
        let brief = ArchitecturalBrief(
            prose: try journal.architecturalBriefProse(cardID: card.id) ?? "",
            transcriptions: try journal.transcriptionBlocks(cardID: card.id).map(\.block)
        )
        _ = try await ManagedBlockMaintenance(journal: journal, outbox: outbox).maintain(card: card, brief: brief)
    }
}
