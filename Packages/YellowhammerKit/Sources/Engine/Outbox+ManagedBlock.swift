import Domain

extension Outbox {
    /// The pre-flight read happens during delivery, under the delivery gate. Targeted reports compose
    /// with other lanes' queued reports and preserve all unrelated text, including blank lines.
    func performManagedBlock(
        issue: BoardObjectID, rendered: String, replacingPrefix prefix: String? = nil
    ) async throws -> Performed {
        let snapshot = try await board.issueDescription(issue)
        var rendered = rendered
        if let prefix {
            switch ManagedBlockFence.parts(of: snapshot.description) {
            case .failure(let failure):
                return .unfenced(failure)
            case .success(let parts):
                var lines = parts.block.split(separator: "\n", omittingEmptySubsequences: false)
                    .map(String.init).filter { !$0.hasPrefix(prefix) }
                if parts.block.isEmpty { lines = [] }
                lines.append(rendered)
                rendered = lines.joined(separator: "\n")
            }
        }
        switch ManagedBlockFence.replace(in: snapshot.description, rendered: rendered) {
        case .failure(let failure):
            return .unfenced(failure)
        case .success(let replacement):
            _ = try await board.updateIssue(issue, BoardIssueChange(description: replacement.description))
            return .fenced(replacement, renderedHash: ManagedBlockFence.sha256(rendered))
        }
    }
}
