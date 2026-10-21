import Domain
import Foundation
import Journal
import Repositories

/// Pushes a Repo Lane's Feature Branch to GitHub (P10.2), the real seam behind ``LanePushing``. Reuses
/// ``FeatureBranchPusher`` for the git-level push (P6.6); this type adds the land-scoped policy in
/// front of it: resolving the lane's Repo and Feature Branch, detecting a lane with no completed work
/// so it is never pushed (signaling safe release of allocated Worktrees via ``LanePushOutcome/safeToReleaseWorktree``),
/// and resolving the push credential lazily, once per call, only when a real push is about to run.
public struct FeatureBranchLanePush: LanePushing, Sendable {
    private let pusher: FeatureBranchPusher
    /// Returns the credential to push with, or throws when it could not be resolved. Called only
    /// once a lane is known to have completed work — never eagerly, and never in rehearsal (the land
    /// Act never calls this seam in rehearsal mode).
    private let credential: @Sendable () throws -> PushCredential?

    public init(
        pusher: FeatureBranchPusher = FeatureBranchPusher(),
        credential: @escaping @Sendable () throws -> PushCredential?
    ) {
        self.pusher = pusher
        self.credential = credential
    }

    public func push(_ context: LandActLaneContext) async throws -> LanePushOutcome {
        let repository = context.lane.repository
        guard let repo = context.act.repositories?.workingRepos.first(where: { $0.name == repository }) else {
            return LanePushOutcome(kind: .failed(reason: "no repository named \"\(repository)\" is configured"))
        }
        let resolved = try context.act.journal.resolvedFeatureBranch(feature: context.feature, repository: repository)
        guard let branch = resolved else {
            return LanePushOutcome(
                kind: .failed(reason: "the Feature has no recorded Feature Branch for \"\(repository)\"")
            )
        }

        let path = (repo.path as NSString).expandingTildeInPath
        // The Mainline-refusal check comes first: the Feature Branch equal to the repository's default
        // branch is never "no completed work" (its rev-list count against itself is zero) — it is a
        // refused Mainline push, left to ``FeatureBranchPusher`` itself to report.
        let defaultBranch = await MainlineRefresher(git: pusher.git).resolveDefaultBranch(for: repo, in: path)
        if branch.name != defaultBranch {
            let recordedBase = try context.act.journal.featureBases(featureID: context.feature.id)
                .first { $0.repository == repository }
            guard await hasCompletedWork(branch: branch, path: path, recordedBase: recordedBase) else {
                return LanePushOutcome(kind: .noCompletedWork)
            }
        }

        let resolvedCredential: PushCredential?
        do {
            resolvedCredential = try credential()
        } catch {
            return LanePushOutcome(kind: .credentialsMissingOrInsufficient(
                detail: "GitHub credentials for \"\(repository)\" could not be resolved: \(error)"
            ))
        }

        let outcome = await pusher.push(
            branch: branch, in: repo, mode: context.act.mode, credential: resolvedCredential
        )
        return Self.map(outcome)
    }

    /// Whether the Feature Branch exists in the repository and has at least one commit not already in its
    /// base. The base is the Feature's **recorded** `effective_base(R)` (`feature_base.base_commit`, written at
    /// selection; spec: landing/open-one-pull-request-per-repository, `hasNetChange`; agent ruling 11), never a
    /// base recomputed at landing: once a stacked-on predecessor has merged, a recomputed base would read
    /// mainline commits the predecessor's tip lacks as this lane's work. A branch that does not exist, or has zero
    /// commits ahead of its base, has no completed work and is never pushed. When the base cannot be resolved at
    /// all (including a missing recorded base), or `rev-list` fails, the branch is treated as having work — this
    /// must never drop commits.
    private func hasCompletedWork(
        branch: FeatureBranch, path: String, recordedBase: FeatureBaseRecord?
    ) async -> Bool {
        let branchRef = "refs/heads/\(branch.name)"
        let branchExists = await pusher.git.run([
            "-C", path, "rev-parse", "--verify", "--quiet", "\(branchRef)^{commit}"
        ]).isSuccess
        guard branchExists else { return false }

        guard let recordedBase else {
            return true
        }
        let baseCommit = recordedBase.baseCommit

        let result = await pusher.git.run(["-C", path, "rev-list", "--count", "\(baseCommit)..\(branchRef)"])
        guard
            result.isSuccess,
            let count = Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            return true
        }
        return count > 0
    }

    private static func map(_ outcome: PushOutcome) -> LanePushOutcome {
        switch outcome {
        case .pushed(let commit):
            return LanePushOutcome(kind: .pushed(commit: commit))
        case .refusedByBranchProtection(_, let detail):
            return LanePushOutcome(kind: .refusedByBranchProtection(detail: detail))
        case .credentialsMissingOrInsufficient(_, let detail):
            return LanePushOutcome(kind: .credentialsMissingOrInsufficient(detail: detail))
        case .notPushedInRehearsal:
            // The land Act never calls this seam in rehearsal mode (a rehearsal boundary enforced
            // above this seam); reaching this case would itself be a defect, so it maps to a failure.
            return LanePushOutcome(kind: .failed(reason: "not pushed in rehearsal"))
        case .refusedMainline:
            return LanePushOutcome(kind: .refusedMainline)
        case .failed(_, let reason):
            return LanePushOutcome(kind: .failed(reason: reason))
        }
    }
}
