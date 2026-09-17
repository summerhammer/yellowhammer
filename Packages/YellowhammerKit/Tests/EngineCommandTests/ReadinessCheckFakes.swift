import Domain
import Foundation

@testable import Engine
@testable import Repositories

/// A scripted `ProvenanceTesting`: returns the verdict keyed by repository name, `.clean` when unset.
struct FakeProvenanceTester: ProvenanceTesting {
    var verdicts: [String: ProvenanceVerdict] = [:]

    func evaluate(
        _ blocks: [TranscriptionBlock], projectRepositories: ProjectRepositories, mainlines: ResolvedMainlines
    ) async -> CardProvenanceReport {
        let results = blocks.map { block in
            RepoProvenanceResult(
                repository: block.repository, recordedPaths: block.paths, recordedCommit: block.mainlineCommit,
                verdict: block.authorSupplied ? .operatorSupplied : (verdicts[block.repository] ?? .clean)
            )
        }
        return CardProvenanceReport(results: results)
    }
}

/// A scripted `CitationResolving`: resolves any citation in `resolvable`, refuses everything else.
struct FakeCitationResolver: CitationResolving {
    // "resolvable/story" is always resolvable: it's the citation the shared fixture's always-Ready
    // second Card carries, so tests that don't care about citation resolution can ignore it.
    var resolvable: Set<String> = ["resolvable/story"]

    func resolve(
        _ citation: SpecCitation, in projectRepositories: ProjectRepositories, mainlines: ResolvedMainlines
    ) async -> SpecCitationResolution {
        if resolvable.contains(citation.rawValue) {
            return .resolved(
                citation: citation, resolvedPath: "docs/\(citation.rawValue).md", commit: "deadbeef",
                repository: "spec_source"
            )
        }
        return .unresolved(citation: citation, reason: "not in the fake's resolvable set")
    }
}
