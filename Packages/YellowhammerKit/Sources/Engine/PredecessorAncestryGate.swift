import Domain
import Foundation
import Journal
import Repositories

/// What the predecessor-ancestry gate does once every repository that pushed a Feature Branch (N) has
/// merged the predecessor Feature's branch — the real close-by-merge work is ``FeatureMergeClosure`` (roadmap P10.8). Nil
/// means skip it: there is nothing to close yet.
public protocol PostMergeClosure: Sendable {
    func closeByMerge(feature: FeatureRecord, context: ActContext) async throws
}

/// What is wrong with the predecessor Feature's recorded state, such that the gate refuses to guess.
public enum PredecessorAncestryGateError: Error, Sendable, Equatable {
    /// A repository in N has no recorded Feature Branch and no Observed Merge — whether or not a landed commit
    /// was recorded: a fault in Yellowhammer's own Journal, never a quiet Night (feature-authoring/
    /// select-the-next-feature, #tested-tip). The Feature's Worktree name does not stand in for the branch
    /// here. A recorded branch whose tip cannot be resolved is indeterminate instead.
    case predecessorBranchMissing(featureIssueID: String)
    /// The predecessor's Cycle pushed a Feature Branch for a repository this Project has no configuration for.
    case predecessorRepositoryNotConfigured(featureIssueID: String, repository: String)
    /// A predecessor Feature exists, but this invocation was given no Project repositories to check
    /// ancestry against.
    case noRepositoriesConfigured(featureIssueID: String)
}

extension PredecessorAncestryGateError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .predecessorBranchMissing(let featureIssueID):
            return """
                Predecessor Feature '\(featureIssueID)' has a repository with no recorded Feature Branch.
                """
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
/// flight. A repository already recorded landed (an Observed Merge) reads no git at all; a repository with
/// no recorded Feature Branch only throws when it still needs a fresh test.
///
/// The merge test per repository is ancestry first, then — only where that fails — the content test, so a
/// predecessor merged with Squash and merge or Rebase and merge opens the gate too. The tested tip is the
/// commit the land Act recorded, not a branch ref (see ``TestedTip``). The test itself is in
/// `PredecessorAncestryGate+MergeTest.swift`.
///
/// The pass runs over N (``JournalStore/pushedRepositories(featureID:)``), never over a repository with a
/// No-Pushed-Branch Outcome: its Feature Branch sits at its base and is trivially an ancestor of
/// mainline, so reading it as a landing is the bug OQ107 closes. Nothing over the empty set reads as
/// merged: at N = 0 there is no pass, no landing, no observation and no closure.
public struct PredecessorAncestryGate: PredecessorGate {
    public let ancestryTester: AncestryTester
    public let mergeTester: MergeTester
    /// The real closure seam is ``FeatureMergeClosure`` (P10.8); nil skips it (see ``PostMergeClosure``).
    public let closure: (any PostMergeClosure)?
    /// Deletes a repository's `refs/yellowhammer/landed/<branch>` pin once its Observed Merge is recorded.
    public let landedTipPin: LandedTipPin

    public init(
        ancestryTester: AncestryTester = AncestryTester(),
        mergeTester: MergeTester = MergeTester(),
        closure: (any PostMergeClosure)? = nil,
        landedTipPin: LandedTipPin = LandedTipPin()
    ) {
        self.ancestryTester = ancestryTester
        self.mergeTester = mergeTester
        self.closure = closure
        self.landedTipPin = landedTipPin
    }

    public func check(_ context: ActContext) async throws -> PredecessorGateOutcome {
        let journal = context.journal

        // An in-flight Feature is observed (never gated on) so its landings accumulate before it
        // becomes tomorrow's predecessor — but only once the land Act has landed its Cycle: a branch
        // freshly cut from mainline is trivially an ancestor of mainline, so an unlanded Cycle must
        // never be read as a landing.
        if try journal.inFlightFeature() != nil {
            if let inFlight = try journal.inFlightLandedFeature(), !inFlight.pushedRepositories.isEmpty {
                _ = try await runAncestryPass(
                    feature: inFlight.feature, pushedRepositories: inFlight.pushedRepositories, context: context
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

        // A predecessor with N = 0 has nothing to check ancestry against: no pass and no closure. This is
        // not "all N merged". It is unreachable for a Feature whose every repository has the No-Pushed-Branch
        // Outcome (the land Act never archives it and closure by merge never fires, so it never becomes a
        // predecessor); what reaches here is a Journal with no touched repositories recorded.
        if predecessor.pushedRepositories.isEmpty {
            return .landed
        }

        return try await runAncestryPass(
            feature: predecessor.feature, pushedRepositories: predecessor.pushedRepositories, context: context
        )
    }

    /// One pass over one Feature's pushed repositories (N): repositories with an Observed Merge are
    /// counted merged with no git read at all; the rest are merge-tested (ancestry, then the content test),
    /// an Observed Merge recorded for each that passed, and a Mainline Conflict reported for each that did
    /// not. Records `predecessorAncestryObserved` every time it runs, and fires the closure seam the first
    /// pass that finds every repository in N merged.
    private func runAncestryPass(
        feature: FeatureRecord, pushedRepositories: [String], context: ActContext
    ) async throws -> PredecessorGateOutcome {
        let journal = context.journal
        let recordedLandings = try journal.landings(featureID: feature.id)
        var mergedRepositories = pushedRepositories.filter { recordedLandings[$0] != nil }
        let toTest = pushedRepositories.filter { recordedLandings[$0] == nil }

        let tested = try await testUntestedRepositories(toTest, feature: feature, context: context)
        mergedRepositories.append(contentsOf: tested.merged)
        mergedRepositories.sort()

        return try await recordPassOutcome(
            feature: feature, mergedRepositories: mergedRepositories,
            unmergedRepositories: tested.unmerged.sorted(),
            indeterminateRepositories: tested.indeterminate.sorted(), context: context
        )
    }

    /// Fires the closure seam the first pass that finds every repository in N merged, records
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
        // Never vacuously true: nothing over the empty set reads as merged, even if a guard above is bypassed.
        let fullyMerged = !mergedRepositories.isEmpty && unmergedRepositories.isEmpty
            && indeterminateRepositories.isEmpty

        // First pass observing all-N merged: the closure seam (P10.8) has not yet closed this
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
}
