import Domain
import Journal

extension Outbox {
    /// The fresh block with every line starting `prefix` replaced by `line`, appended last.
    private static func patchingLine(
        _ line: String, prefix: String, in description: String?
    ) -> Result<String, ManagedBlockFence.Failure> {
        switch ManagedBlockFence.parts(of: description) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let parts):
            var lines = parts.block.split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init).filter { !$0.hasPrefix(prefix) }
            if parts.block.isEmpty { lines = [] }
            lines.append(line)
            return .success(lines.joined(separator: "\n"))
        }
    }

    private static func patchingLines(
        _ lines: [String], prefix: String, in description: String?
    ) -> Result<[String], ManagedBlockFence.Failure> {
        var blocks: [String] = []
        for line in lines {
            switch patchingLine(line, prefix: prefix, in: description) {
            case .failure(let failure): return .failure(failure)
            case .success(let patched): blocks.append(patched)
            }
        }
        return .success(blocks)
    }

    /// The pre-flight read happens during delivery, under the delivery gate. Targeted reports compose
    /// with other lanes' queued reports and preserve all unrelated text, including blank lines.
    ///
    /// `renderings` run from the full one to the most compacted. With a `prefix` each is a report's lines,
    /// patched into the fresh block (every line starting `prefix` dropped, the rendering appended); without
    /// one each is the whole block. With a description budget, the first whose whole replaced description
    /// fits is the one written, and the hash of its block is what is recorded; when none fits the write is
    /// refused (``Performed/overBudget(length:budget:cause:)``), naming the report by its prefix when there
    /// is one (spec: board-projection/maintain-the-managed-block, budget on rewrite; issue #670).
    func performManagedBlock(
        issue: BoardObjectID, renderings: [String], replacingPrefix prefix: String? = nil, entry: OutboxEntry
    ) async throws -> Performed {
        let snapshot = try await board.issueDescription(issue)
        var blocks = renderings
        // A targeted line update keeps the rest of the fresh block as read, so it cannot erase an edit; a
        // full rendering can, and imports what the description holds first.
        if prefix == nil, let held = try importFreshInput(from: snapshot, issue: issue, renderings: renderings) {
            return held
        }
        if let prefix {
            switch Self.patchingLines(renderings, prefix: prefix, in: snapshot.description) {
            case .failure(let failure): return .unfenced(failure)
            case .success(let patched): blocks = patched
            }
        }
        var mostCompacted: (length: Int, index: Int)?
        for (index, rendered) in blocks.enumerated() {
            switch ManagedBlockFence.replace(in: snapshot.description, rendered: rendered) {
            case .failure(let failure):
                return .unfenced(failure)
            case .success(let replacement):
                if let descriptionBudget, !descriptionBudget.fits(replacement.description) {
                    mostCompacted = (descriptionBudget.measure(replacement.description), index)
                    continue
                }
                // The description read awaited the board: revalidate immediately before the mutation.
                let object = try await reading?.issue(issue)
                try journal.revalidateOutboxLeases(for: entry, runID: runID, now: clock())
                if object?.archivedAt != nil { throw OutboxError.archivedIssue(issue) }
                _ = try await board.updateIssue(issue, BoardIssueChange(description: replacement.description))
                return .fenced(replacement, renderedHash: ManagedBlockFence.sha256(rendered))
            }
        }
        guard let descriptionBudget, let mostCompacted else { throw OutboxError.payloadUnreadable(entryID: entry.id) }
        // A report is measured alone as its own lines; a whole block as it is.
        let alone = descriptionBudget.fits(
            ManagedBlockFence.initialDescription(rendered: renderings[mostCompacted.index])
        )
        let cause: OverBudgetCause = prefix.map { .lineUpdate(prefix: $0, reportAloneFits: alone) }
            ?? .blockRewrite(renderingAloneFits: alone)
        return .overBudget(length: mostCompacted.length, budget: descriptionBudget, cause: cause)
    }
}
