import Domain
import Foundation
import Repositories

/// Pushes a Repo Lane's Feature Branch to GitHub (P10.2), the real seam behind ``LanePushing``. Reuses
/// ``FeatureBranchPusher`` for the git-level push (P6.6); this type adds the land-scoped policy in
/// front of it: resolving the lane's Repo and Feature Branch, detecting a lane with no completed work
/// so it is never pushed (signaling safe release of allocated Worktrees via ``LanePushOutcome/safeToReleaseWorktree``),
/// and resolving the GitHub token lazily, once per call, only when a real push is about to run.
public struct FeatureBranchLanePush: LanePushing, Sendable {
    private let pusher: FeatureBranchPusher
    /// Returns the GitHub token to push with, or throws when it could not be resolved. Called only
    /// once a lane is known to have completed work — never eagerly, and never in rehearsal (the land
    /// Act never calls this seam in rehearsal mode).
    private let token: @Sendable () throws -> GitHubToken?

    public init(
        pusher: FeatureBranchPusher = FeatureBranchPusher(),
        token: @escaping @Sendable () throws -> GitHubToken?
    ) {
        self.pusher = pusher
        self.token = token
    }

    public func push(_ context: LandActLaneContext) async throws -> LanePushOutcome {
        let repository = context.lane.repository
        guard let repo = context.act.repositories?.workingRepos.first(where: { $0.name == repository }) else {
            return LanePushOutcome(kind: .failed(reason: "no repository named \"\(repository)\" is configured"))
        }
        guard let branch = context.feature.branch else {
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
            guard await hasCompletedWork(branch: branch, path: path, mainlines: context.act.mainlines, repo: repo)
            else {
                return LanePushOutcome(kind: .noCompletedWork)
            }
        }

        let resolvedToken: GitHubToken?
        do {
            resolvedToken = try token()
        } catch {
            return LanePushOutcome(kind: .credentialsMissingOrInsufficient(
                detail: "GitHub credentials for \"\(repository)\" could not be resolved: \(error)"
            ))
        }

        let outcome = await pusher.push(branch: branch, in: repo, mode: context.act.mode, token: resolvedToken)
        return Self.map(outcome)
    }

    /// Whether the Feature Branch exists in the repository and has at least one commit not already in
    /// Mainline. A branch that does not exist, or has zero commits ahead of Mainline, has no completed
    /// work and is never pushed. When Mainline cannot be resolved at all, the branch is treated as
    /// having work — this must never drop commits.
    private func hasCompletedWork(
        branch: FeatureBranch, path: String, mainlines: ResolvedMainlines, repo: Repo
    ) async -> Bool {
        let branchRef = "refs/heads/\(branch.name)"
        let branchExists = await pusher.git.run([
            "-C", path, "rev-parse", "--verify", "--quiet", "\(branchRef)^{commit}"
        ]).isSuccess
        guard branchExists else { return false }

        guard let mainlineCommit = await resolveMainlineCommit(repo: repo, path: path, mainlines: mainlines) else {
            return true
        }

        let result = await pusher.git.run(["-C", path, "rev-list", "--count", "\(mainlineCommit)..\(branchRef)"])
        guard
            result.isSuccess,
            let count = Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            return true
        }
        return count > 0
    }

    /// Mirrors ``AncestryTester``'s and ``MergeTester``'s own mainline resolution: the pre-resolved
    /// commit from ``ActContext/mainlines`` when this repository has one, else the repository's default
    /// branch resolved locally (remote-tracking ref, then local ref, then `HEAD`). Nil when none of
    /// these resolve.
    private func resolveMainlineCommit(repo: Repo, path: String, mainlines: ResolvedMainlines) async -> String? {
        if let resolved = mainlines[repo.name] {
            return resolved.commit
        }
        let defaultBranch = await MainlineRefresher(git: pusher.git).resolveDefaultBranch(for: repo, in: path)
        let candidates = [
            "refs/remotes/origin/\(defaultBranch)",
            "refs/heads/\(defaultBranch)",
            "HEAD"
        ]
        for ref in candidates {
            let result = await pusher.git.run(["-C", path, "rev-parse", "--verify", "--quiet", "\(ref)^{commit}"])
            guard result.isSuccess else { continue }
            let sha = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sha.isEmpty { return sha }
        }
        return nil
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
