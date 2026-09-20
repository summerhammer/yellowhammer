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
    /// A predecessor Feature exists but has no recorded Feature Branch, and at least one touched
    /// repository has no recorded landing to fall back on.
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

/// The real predecessor-ancestry gate (roadmap P9.2, P9.9; spec: feature-authoring/
/// select-the-next-feature, third story; glossary "Mainline Conflict"). Pure local git, run strictly
/// before authoring: allocates no Worktree, dispatches nothing, records no Attempt.
///
/// Runs its ancestry pass every Night, on whichever Feature is relevant (roadmap P9.9): the in-flight
/// Feature when one is open and its Cycle has landed, or the walk's predecessor when nothing is in
/// flight. A repository already recorded landed reads no git at all; a Feature with a nil branch only
/// throws when some touched repository still needs a fresh ancestry test.
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
        let journal = context.journal

        // An in-flight Feature is observed (never gated on) so its landings accumulate before it
        // becomes tomorrow's predecessor — but only once the land Act has landed its Cycle: a branch
        // freshly cut from mainline is trivially an ancestor of mainline, so an unlanded Cycle must
        // never be read as a landing.
        if try journal.inFlightFeature() != nil {
            if let inFlight = try journal.inFlightLandedFeature(), !inFlight.touchedRepositories.isEmpty {
                _ = try await runAncestryPass(
                    feature: inFlight.feature, touchedRepositories: inFlight.touchedRepositories, context: context
                )
            }
            return .landed
        }

        let walk = try journal.predecessorFeature()
        let outcome = try await checkPredecessor(walk.predecessor, context: context)
        // Recorded only when authoring proceeds: that is the Night a successor is built without the
        // released Feature's work, which is what the Night Summary has to name.
        if outcome == .landed {
            for skipped in walk.skippedReleased {
                try journal.append(
                    .predecessorWalkSkippedReleasedFeature(featureIssueID: skipped.issueID),
                    act: context.act, runID: context.runID, nightID: context.night.id
                )
            }
        }
        return outcome
    }

    private func checkPredecessor(
        _ predecessor: PredecessorFeature?, context: ActContext
    ) async throws -> PredecessorGateOutcome {
        guard let predecessor else { return .landed }

        // A predecessor whose Cycle touched zero repositories has nothing to check ancestry against.
        if predecessor.touchedRepositories.isEmpty {
            return .landed
        }

        return try await runAncestryPass(
            feature: predecessor.feature, touchedRepositories: predecessor.touchedRepositories, context: context
        )
    }

    /// One pass's repositories, split by what this pass found: freshly merged (a landing was just
    /// recorded), unmerged (a known commit, not an ancestor) and indeterminate (no commit could be
    /// resolved for the branch at all). A named type rather than a wide tuple.
    private struct AncestryTestResult {
        var merged: [String] = []
        var unmerged: [String] = []
        var indeterminate: [String] = []
    }

    /// One pass over one Feature's touched repositories: repositories with a recorded landing are
    /// counted merged with no git read at all; the rest are ancestry-tested, a fresh landing recorded
    /// for each that merged, and a Mainline Conflict re-tested for each that did not. Records
    /// `predecessorAncestryObserved` every time it runs, and fires the closure seam the first pass that
    /// finds every touched repository merged.
    private func runAncestryPass(
        feature: FeatureRecord, touchedRepositories: [String], context: ActContext
    ) async throws -> PredecessorGateOutcome {
        let journal = context.journal
        let recordedLandings = try journal.landings(featureID: feature.id)
        var mergedRepositories = touchedRepositories.filter { recordedLandings[$0] != nil }
        let toTest = touchedRepositories.filter { recordedLandings[$0] == nil }

        let tested = try await testUntestedRepositories(toTest, feature: feature, context: context)
        mergedRepositories.append(contentsOf: tested.merged)
        mergedRepositories.sort()

        return try await recordPassOutcome(
            feature: feature, mergedRepositories: mergedRepositories,
            unmergedRepositories: tested.unmerged.sorted(),
            indeterminateRepositories: tested.indeterminate.sorted(), context: context
        )
    }

    /// Ancestry-tests the repositories with no recorded landing yet: a fresh landing is recorded for
    /// each that merged, and a Mainline Conflict is re-tested for each that did not. Empty input skips
    /// git entirely.
    private func testUntestedRepositories(
        _ toTest: [String], feature: FeatureRecord, context: ActContext
    ) async throws -> AncestryTestResult {
        guard !toTest.isEmpty else { return AncestryTestResult() }
        guard let branch = feature.branch else {
            throw PredecessorAncestryGateError.predecessorBranchMissing(featureIssueID: feature.issueID)
        }
        let repos = try Self.resolveRepos(featureIssueID: feature.issueID, names: toTest, in: context.repositories)
        let ancestryReport = await ancestryTester.evaluateAncestry(
            branch: branch, repos: repos, mainlines: context.mainlines
        )

        var result = AncestryTestResult()
        for repoResult in ancestryReport.results {
            if repoResult.isAncestor, let mainlineCommit = repoResult.mainlineCommit {
                try context.journal.recordLanding(
                    featureID: feature.id, repository: repoResult.repository, mainlineCommit: mainlineCommit
                )
                result.merged.append(repoResult.repository)
            } else if repoResult.branchCommit == nil {
                result.indeterminate.append(repoResult.repository)
            } else {
                result.unmerged.append(repoResult.repository)
            }
        }

        if !result.unmerged.isEmpty {
            try await reportMainlineConflicts(
                branch: branch, repos: repos, unmergedRepositories: result.unmerged.sorted(),
                feature: feature, context: context
            )
        }
        return result
    }

    /// Fires the closure seam the first pass that finds every touched repository merged, records
    /// `predecessorAncestryObserved`, and derives this pass's outcome — indeterminate takes precedence
    /// over notLanded.
    private func recordPassOutcome(
        feature: FeatureRecord, mergedRepositories: [String], unmergedRepositories: [String],
        indeterminateRepositories: [String], context: ActContext
    ) async throws -> PredecessorGateOutcome {
        let journal = context.journal
        // Checked before this pass's own event is appended, and against the Journal rather than
        // in-memory state, so a second pass in a later process still sees the first pass's record.
        let alreadyFullyMerged = try journal.predecessorAncestryPreviouslyFullyMerged(featureIssueID: feature.issueID)
        let fullyMerged = unmergedRepositories.isEmpty && indeterminateRepositories.isEmpty

        // First pass observing all-N merged: the closure seam (P10.8) has not yet run for this
        // Feature. It runs before this pass's event is appended, so a closure that threw or died
        // part-way is not recorded as done and is reclaimable by the next pass.
        if fullyMerged, !alreadyFullyMerged {
            try await closure?.closeByMerge(feature: feature, context: context)
        }

        try journal.append(
            .predecessorAncestryObserved(
                featureIssueID: feature.issueID,
                mergedRepositories: mergedRepositories,
                unmergedRepositories: (unmergedRepositories + indeterminateRepositories).sorted()
            ),
            act: context.act, runID: context.runID, nightID: context.night.id
        )

        if !indeterminateRepositories.isEmpty {
            return .indeterminate(predecessorIssueID: feature.issueID, repositories: indeterminateRepositories)
        }
        guard unmergedRepositories.isEmpty else {
            return .notLanded(predecessorIssueID: feature.issueID, repositories: unmergedRepositories)
        }
        return .landed
    }

    /// Resolves the Project's configured `Repo`s for every repository name given. Throws when this
    /// Project has no repositories at all, or when one of them is not among its own — the gate never
    /// guesses, and never reads a repo outside this Project's scope.
    private static func resolveRepos(
        featureIssueID: String, names: [String], in repositories: ProjectRepositories?
    ) throws -> [Repo] {
        guard let repositories else {
            throw PredecessorAncestryGateError.noRepositoriesConfigured(featureIssueID: featureIssueID)
        }
        return try names.map { name in
            guard let repo = repositories.workingRepo(named: name) else {
                throw PredecessorAncestryGateError.predecessorRepositoryNotConfigured(
                    featureIssueID: featureIssueID, repository: name
                )
            }
            return repo
        }
    }

    /// Re-runs the merge test on the unmerged repositories only, and records one
    /// `mainlineConflictDetected` per repository whose test found a Mainline Conflict.
    private func reportMainlineConflicts(
        branch: FeatureBranch, repos: [Repo], unmergedRepositories: [String],
        feature: FeatureRecord, context: ActContext
    ) async throws {
        let unmergedRepos = repos.filter { unmergedRepositories.contains($0.name) }
        let mergeReport = await mergeTester.evaluateMerge(
            branch: branch, repos: unmergedRepos, mainlines: context.mainlines
        )
        for result in mergeReport.results where result.isMainlineConflict {
            try context.journal.append(
                .mainlineConflictDetected(
                    featureIssueID: feature.issueID,
                    repository: result.repository,
                    paths: result.conflictingPaths
                ),
                act: context.act, runID: context.runID, nightID: context.night.id
            )
        }
    }
}
