import Domain
import Foundation

/// The verdict of a local provenance test: whether a recorded contract path has changed between
/// the recorded commit and mainline head.
public enum ProvenanceVerdict: Equatable, Sendable {
    case clean
    case stale(changedPaths: [String])
    case operatorSupplied
    case untestable(reason: String)
}

/// The result of a provenance test for a single repository or transcription block.
public struct RepoProvenanceResult: Equatable, Sendable {
    public let repository: String
    public let recordedPaths: [String]
    public let recordedCommit: String?
    public let mainlineRef: String?
    public let mainlineCommit: String?
    public let verdict: ProvenanceVerdict

    /// True only if `verdict` is `.stale`.
    public var isDiverged: Bool {
        if case .stale = verdict { return true }
        return false
    }

    /// The changed paths from `.stale`, or empty.
    public var changedPaths: [String] {
        if case .stale(let paths) = verdict { return paths }
        return []
    }

    /// True for `.clean` and `.operatorSupplied`.
    public var isStillGood: Bool {
        switch verdict {
        case .clean, .operatorSupplied:
            return true
        case .stale, .untestable:
            return false
        }
    }

    public init(
        repository: String,
        recordedPaths: [String],
        recordedCommit: String?,
        mainlineRef: String? = nil,
        mainlineCommit: String? = nil,
        verdict: ProvenanceVerdict
    ) {
        self.repository = repository
        self.recordedPaths = recordedPaths
        self.recordedCommit = recordedCommit
        self.mainlineRef = mainlineRef
        self.mainlineCommit = mainlineCommit
        self.verdict = verdict
    }
}

/// A report of provenance checks across all transcription blocks or repositories for a Card.
public struct CardProvenanceReport: Equatable, Sendable {
    public let results: [RepoProvenanceResult]

    /// Whether all transcription results are still good.
    public var isAllClean: Bool {
        results.allSatisfy(\.isStillGood)
    }

    /// Whether any transcription result has diverged.
    public var hasDivergence: Bool {
        results.contains(where: \.isDiverged)
    }

    /// Unique repository names that have diverged, in order of appearance.
    public var divergedRepositories: [String] {
        var seen = Set<String>()
        var list: [String] = []
        for result in results where result.isDiverged {
            if seen.insert(result.repository).inserted {
                list.append(result.repository)
            }
        }
        return list
    }

    /// Sorted deduplicated array of all changed paths across all results.
    public var allChangedPaths: [String] {
        let paths = results.flatMap(\.changedPaths)
        return Array(Set(paths)).sorted()
    }

    public subscript(repositoryName: String) -> RepoProvenanceResult? {
        results.first { $0.repository == repositoryName }
    }

    public subscript(repo: Repo) -> RepoProvenanceResult? {
        results.first { $0.repository == repo.name }
    }

    public init(results: [RepoProvenanceResult] = []) {
        self.results = results
    }
}
