import Domain
import Journal

extension Outbox {
    /// The pre-flight read happens during delivery, under the delivery gate. Targeted reports compose
    /// with other lanes' queued reports and preserve all unrelated text, including blank lines.
    ///
    /// `renderings` run from the full one to the most compacted. With a description budget, the first
    /// whose whole replaced description fits is the one written, and its own hash is what is recorded;
    /// when none fits the write is refused (``Performed/overBudget(length:budget:renderingAloneFits:)``).
    /// A targeted line update, which has no ladder, is refused the same way when it does not fit.
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

    func performManagedBlock(
        issue: BoardObjectID, renderings: [String], replacingPrefix prefix: String? = nil, entry: OutboxEntry
    ) async throws -> Performed {
        let snapshot = try await board.issueDescription(issue)
        var renderings = renderings
        // A targeted line update keeps the rest of the fresh block as read, so it cannot erase an edit; a
        // full rendering can, and imports what the description holds first.
        if prefix == nil, let held = try importFreshInput(from: snapshot, issue: issue, renderings: renderings) {
            return held
        }
        if let prefix, let line = renderings.first {
            switch Self.patchingLine(line, prefix: prefix, in: snapshot.description) {
            case .failure(let failure): return .unfenced(failure)
            case .success(let patched): renderings = [patched]
            }
        }
        var mostCompacted: (length: Int, rendering: String)?
        for rendered in renderings {
            switch ManagedBlockFence.replace(in: snapshot.description, rendered: rendered) {
            case .failure(let failure):
                return .unfenced(failure)
            case .success(let replacement):
                if let descriptionBudget, !descriptionBudget.fits(replacement.description) {
                    mostCompacted = (descriptionBudget.measure(replacement.description), rendered)
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
        let alone = ManagedBlockFence.initialDescription(rendered: mostCompacted.rendering)
        return .overBudget(
            length: mostCompacted.length, budget: descriptionBudget, renderingAloneFits: descriptionBudget.fits(alone)
        )
    }
}
