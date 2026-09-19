import Domain
import Foundation
import Journal
import Repositories

/// What the predecessor-ancestry gate does once every touched repository has merged the predecessor
/// Feature's branch — the real close-by-merge work is roadmap P10.8, not this phase. Nil means skip
/// it: there is nothing to close yet.
public protocol PostMergeClosure: Sendable {
    func closeByMerge(feature: FeatureRecord, context: ActContext) async throws
}

/// What is wrong with the predecessor Feature's recorded state, such that the gate refuses to guess.
public enum PredecessorAncestryGateError: Error, Sendable, Equatable {
    /// A predecessor Feature exists but has no recorded Feature Branch.
    case predecessorBranchMissing(featureIssueID: String)
    /// The predecessor's Cycle touched a repository this Project has no configuration for.
    case predecessorRepositoryNotConfigured(featureIssueID: String, repository: String)
    /// A predecessor Feature exists, but this invocation was given no Project repositories to check
    /// ancestry against.
    case noRepositoriesConfigured(featureIssueID: String)
}

extension PredecessorAncestryGateError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .predecessorBranchMissing(let featureIssueID):
            return "Predecessor Feature '\(featureIssueID)' has no recorded Feature Branch."
        case .predecessorRepositoryNotConfigured(let featureIssueID, let repository):
            return """
                Predecessor Feature '\(featureIssueID)' touched repository '\(repository)', which is not \
                configured for this Project.
                """
        case .noRepositoriesConfigured(let featureIssueID):
            return "Predecessor Feature '\(featureIssueID)' exists, but this Project has no repositories configured."
        }
    }
}

/// The real predecessor-ancestry gate (roadmap P9.2; spec: feature-authoring/select-the-next-feature,
/// third story; glossary "Mainline Conflict"). Pure local git, run strictly before authoring:
/// allocates no Worktree, dispatches nothing, records no Attempt.
public struct PredecessorAncestryGate: PredecessorGate {
    public let ancestryTester: AncestryTester
    public let mergeTester: MergeTester
    /// P10.8's closure seam; nil skips it (see ``PostMergeClosure``).
    public let closure: (any PostMergeClosure)?

    public init(
        ancestryTester: AncestryTester = AncestryTester(),
        mergeTester: MergeTester = MergeTester(),
        closure: (any PostMergeClosure)? = nil
    ) {
        self.ancestryTester = ancestryTester
        self.mergeTester = mergeTester
        self.closure = closure
    }

    public func check(_ context: ActContext) async throws -> PredecessorGateOutcome {
        guard let predecessor = try context.journal.predecessorFeature() else {
            return .landed
        }

        // A predecessor whose Cycle touched zero repositories has nothing to check ancestry against.
        if predecessor.touchedRepositories.isEmpty {
            return .landed
        }

        guard let branch = predecessor.feature.branch else {
            throw PredecessorAncestryGateError.predecessorBranchMissing(featureIssueID: predecessor.feature.issueID)
        }

        let repos = try Self.resolveRepos(for: predecessor, in: context.repositories)

        let ancestryReport = await ancestryTester.evaluateAncestry(
            branch: branch, repos: repos, mainlines: context.mainlines
        )
        let mergedRepositories = ancestryReport.mergedRepositories.sorted()
        let unmergedRepositories = ancestryReport.unmergedRepositories.sorted()

        if !unmergedRepositories.isEmpty {
            try await reportMainlineConflicts(
                branch: branch, repos: repos, unmergedRepositories: unmergedRepositories,
                predecessor: predecessor, context: context
            )
        }

        // Checked before this pass's own event is appended, and against the Journal rather than
        // in-memory state, so a second pass in a later process still sees the first pass's record.
        let alreadyFullyMerged = try context.journal.predecessorAncestryPreviouslyFullyMerged(
            featureIssueID: predecessor.feature.issueID
        )

        // First pass observing all-N merged: the closure seam (P10.8) has not yet run for this
        // Feature. It runs before this pass's event is appended, so a closure that threw or died
        // part-way is not recorded as done and is reclaimable by the next pass.
        if unmergedRepositories.isEmpty, !alreadyFullyMerged {
            try await closure?.closeByMerge(feature: predecessor.feature, context: context)
        }

        try context.journal.append(
            .predecessorAncestryObserved(
                featureIssueID: predecessor.feature.issueID,
                mergedRepositories: mergedRepositories,
                unmergedRepositories: unmergedRepositories
            ),
            act: context.act, runID: context.runID, nightID: context.night.id
        )

        guard unmergedRepositories.isEmpty else {
            return .notLanded(predecessorIssueID: predecessor.feature.issueID, repositories: unmergedRepositories)
        }

        return .landed
    }

    /// Resolves the Project's configured `Repo`s for every repository the predecessor's Cycle
    /// touched. Throws when this Project has no repositories at all, or when a touched repository is
    /// not among them — the gate never guesses, and never reads a repo outside this Project's scope.
    private static func resolveRepos(
        for predecessor: PredecessorFeature, in repositories: ProjectRepositories?
    ) throws -> [Repo] {
        guard let repositories else {
            throw PredecessorAncestryGateError.noRepositoriesConfigured(featureIssueID: predecessor.feature.issueID)
        }
        return try predecessor.touchedRepositories.map { name in
            guard let repo = repositories.workingRepo(named: name) else {
                throw PredecessorAncestryGateError.predecessorRepositoryNotConfigured(
                    featureIssueID: predecessor.feature.issueID, repository: name
                )
            }
            return repo
        }
    }

    /// Re-runs the merge test on the unmerged repositories only, and records one
    /// `mainlineConflictDetected` per repository whose test found a Mainline Conflict.
    private func reportMainlineConflicts(
        branch: FeatureBranch, repos: [Repo], unmergedRepositories: [String],
        predecessor: PredecessorFeature, context: ActContext
    ) async throws {
        let unmergedRepos = repos.filter { unmergedRepositories.contains($0.name) }
        let mergeReport = await mergeTester.evaluateMerge(
            branch: branch, repos: unmergedRepos, mainlines: context.mainlines
        )
        for result in mergeReport.results where result.isMainlineConflict {
            try context.journal.append(
                .mainlineConflictDetected(
                    featureIssueID: predecessor.feature.issueID,
                    repository: result.repository,
                    paths: result.conflictingPaths
                ),
                act: context.act, runID: context.runID, nightID: context.night.id
            )
        }
    }
}
