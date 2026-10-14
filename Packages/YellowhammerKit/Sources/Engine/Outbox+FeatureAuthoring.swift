import Domain
import Foundation
import Journal

/// A separate owned prose region: authoring survives later Roll-up replacements of the primary
/// Managed Block. Re-authoring replaces this region; every byte of unrelated prose stays unchanged.
enum FeatureAuthoringProse {
    static let start = "<!-- yh:feature-authoring:start -->"
    static let end = "<!-- yh:feature-authoring:end -->"

    static func replace(in description: String, prose: String) -> String? {
        guard !prose.contains(start), !prose.contains(end) else { return nil }
        let starts = description.components(separatedBy: start).count - 1
        let ends = description.components(separatedBy: end).count - 1
        let region = "\(start)\n\(prose)\n\(end)"
        if starts == 0, ends == 0 { return description + "\n\n" + region }
        guard starts == 1, ends == 1, let from = description.range(of: start),
              let to = description.range(of: end), from.upperBound <= to.lowerBound else { return nil }
        var replacement = description
        replacement.replaceSubrange(from.lowerBound..<to.upperBound, with: region)
        return replacement
    }
}

extension Outbox {
    func performDescription(_ write: BoardWrite, entry: OutboxEntry) async throws -> Performed {
        switch write {
        case .rewriteManagedBlock(let issue, let rendered):
            return try await performManagedBlock(issue: issue, renderings: [rendered], entry: entry)
        case .rewriteManagedBlockCompacting(let issue, let renderings):
            return try await performManagedBlock(issue: issue, renderings: renderings, entry: entry)
        case .rewriteFeatureAuthoring(let issue, let prose):
            return try await performFeatureAuthoring(issue: issue, prose: prose, entry: entry)
        default: throw OutboxError.payloadUnreadable(entryID: entry.id)
        }
    }

    func performFeatureAuthoring(issue: BoardObjectID, prose: String, entry: OutboxEntry) async throws -> Performed {
        let snapshot = try await board.issueDescription(issue)
        let parts: ManagedBlockFence.Parts
        switch ManagedBlockFence.parts(of: snapshot.description) {
        case .failure(let failure): return .unfenced(failure)
        case .success(let value): parts = value
        }
        guard let description = snapshot.description,
              let composed = FeatureAuthoringProse.replace(in: description, prose: prose) else {
            return .unfenced(.featureAuthoringMalformed)
        }
        if let descriptionBudget, !descriptionBudget.fits(composed) {
            return .overBudget(
                length: descriptionBudget.measure(composed), budget: descriptionBudget, renderingAloneFits: false
            )
        }
        let composedParts: ManagedBlockFence.Parts
        switch ManagedBlockFence.parts(of: composed) {
        case .failure(let failure): return .unfenced(failure)
        case .success(let value): composedParts = value
        }
        let object = try await reading?.issue(issue)
        try journal.revalidateOutboxLeases(for: entry, runID: runID, now: clock())
        if object?.archivedAt != nil { throw OutboxError.archivedIssue(issue) }
        _ = try await board.updateIssue(issue, BoardIssueChange(description: composed))
        return .fenced(
            ManagedBlockFence.Replacement(description: composed, preservedProse: composedParts.preservedProse),
            renderedHash: parts.blockHash
        )
    }
}
