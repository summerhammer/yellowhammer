import Domain

/// The contract-overlap floor (feature-authoring/author-the-cycle-and-card-dag, `#contract-overlap`): a Work
/// Card whose `contracts` name paths in a repository that another Work Card of the same Feature writes is a
/// Feature carrying its own upstream. Pure and local: no model call, and it applies whether or not the Project
/// declares any Repo Dependency. A contract naming the Spec Source never overlaps: no Work Card writes it, and a
/// Card's repository is always a working Repo.
enum ContractOverlapCheck {
    /// OQ175(a): whether an empty Declared Scope reads as the whole repository (the floor then fires at repository
    /// level) or as nothing (it catches nothing until scope ships). Open; built as the agent's lean.
    static let emptyScopeReadsAsWholeRepository = true

    /// The overlaps in `breakdown`, one per (reader, writer, repository), cards in breakdown order. `scopes` maps a
    /// writer Card's title to its Declared Scope (paths or directory prefixes); the breakdown emits none today, so
    /// every writer's scope is empty and `emptyScopeReadsAsWholeRepository` decides.
    static func overlaps(
        in breakdown: FeatureBreakdown, scopes: [String: [String]] = [:],
        emptyScopeReadsAsWholeRepository: Bool = ContractOverlapCheck.emptyScopeReadsAsWholeRepository
    ) -> [ContractOverlap] {
        var found: [ContractOverlap] = []
        for (readerIndex, reader) in breakdown.cards.enumerated() {
            for (writerIndex, writer) in breakdown.cards.enumerated() where writerIndex != readerIndex {
                let scope = scopes[writer.title] ?? []
                var paths: [String] = []
                for contract in reader.contracts where contract.repository == writer.repository {
                    let read = scope.isEmpty
                        ? (emptyScopeReadsAsWholeRepository ? contract.paths : [])
                        : contract.paths.filter { path in scope.contains { covers($0, path) } }
                    for path in read where !paths.contains(path) { paths.append(path) }
                }
                guard !paths.isEmpty else { continue }
                found.append(ContractOverlap(
                    readerTitle: reader.title, writerTitle: writer.title, repository: writer.repository, paths: paths
                ))
            }
        }
        return found
    }

    /// Whether the scope entry is the path itself or a directory containing it.
    private static func covers(_ entry: String, _ path: String) -> Bool {
        let directory = entry.hasSuffix("/") ? entry : entry + "/"
        return path == entry || path.hasPrefix(directory)
    }
}
