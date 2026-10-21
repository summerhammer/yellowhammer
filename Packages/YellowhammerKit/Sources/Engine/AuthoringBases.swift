import Domain
import Foundation
import Journal
import Repositories

/// Why `effective_base(R)` could not be resolved for one working repository (roadmap P23.2). Never a reason to
/// fall back to mainline: a Feature authored on the wrong base breaks the authoring invariant.
public enum AuthoringBaseFault: Equatable, Sendable, CustomStringConvertible {
    /// Neither the landed-tip pin nor the remote-tracking Feature Branch resolves in the repository's main clone.
    case unresolved(repository: String, branch: String, featureIssueID: String)
    /// The base resolves, but to a commit other than the one the land Act recorded when it pushed.
    case commitMismatch(
        repository: String, branch: String, featureIssueID: String, resolved: String, recorded: String
    )

    public var repository: String {
        switch self {
        case .unresolved(let repository, _, _), .commitMismatch(let repository, _, _, _, _): repository
        }
    }

    public var description: String {
        switch self {
        case .unresolved(let repository, let branch, _):
            "the effective base of \(repository) could not be resolved: neither "
                + "\(LandedTipPin.ref(for: FeatureBranch(rawValue: branch))) nor refs/remotes/origin/\(branch) "
                + "names a commit in its main clone"
        case .commitMismatch(let repository, let branch, _, let resolved, let recorded):
            "the effective base of \(repository) resolves to \(resolved) for branch \(branch), not to the commit "
                + "\(recorded) the land Act recorded when it pushed"
        }
    }
}

/// What ``AuthoringBases`` resolved: the snapshot to author against, the `feature_base` rows selection records
/// for it, and every repository whose base could not be resolved.
public struct AuthoringBasesResult: Equatable, Sendable {
    /// `effective_base(R)` per working repository, in `ResolvedMainlines`' shape so every authoring-side reader
    /// (selection, breakdown, transcription, citations, readiness) reads it unchanged. The Spec Source entry is
    /// the real mainline's.
    public let mainlines: ResolvedMainlines
    /// One row per working repository with a resolved base, sorted by repository; selection records the rows of
    /// the repositories it touches.
    public let records: [FeatureBaseRecord]
    /// Repositories whose stacked base could not be resolved; when non-empty, nothing may be authored.
    public let faults: [AuthoringBaseFault]
}

/// The base each working Repo is authored against (roadmap P23.2; spec: feature-authoring/select-the-next-feature,
/// `#effective-base`): the pinned landed tip `refs/yellowhammer/landed/<b_last>` (commit `C_last`) of the most
/// recent Feature in the Unmerged Feature Stack U that pushed in the repository, else mainline. Read through `git`
/// in the repository's main clone, never touching its working tree. Local git, not behind a Port.
///
/// `context.mainlines` keeps meaning the real mainline everywhere else — banked-reply stamps, the lane merge
/// test, the predecessor gate. Only the selection call is handed this snapshot (``ActContext/authoring(against:)``).
public enum AuthoringBases {
    /// The bases the author Act selects against, from U as it stands now.
    public static func fromStack(
        context: ActContext, git: GitRunner = GitRunner()
    ) async throws -> AuthoringBasesResult {
        var entries = context.mainlines.workingRepos
        var records: [FeatureBaseRecord] = []
        var faults: [AuthoringBaseFault] = []
        for repo in context.repositories?.workingRepos ?? [] {
            guard let base = try context.journal.effectiveBase(repository: repo.name) else {
                if let mainline = context.mainlines[repo] {
                    records.append(FeatureBaseRecord(
                        repository: repo.name, baseRef: mainline.ref, baseCommit: mainline.commit
                    ))
                }
                continue
            }
            switch await resolve(base, in: repo, git: git) {
            case .success(let resolved):
                entries[repo.name] = ResolvedMainline(
                    repository: repo.name,
                    defaultBranch: context.mainlines[repo]?.defaultBranch ?? repo.defaultBranch ?? "main",
                    ref: resolved.ref, commit: resolved.commit
                )
                records.append(FeatureBaseRecord(
                    repository: repo.name, baseRef: resolved.ref, baseCommit: resolved.commit,
                    stackedOnFeatureID: base.featureID
                ))
            case .failure(let fault):
                faults.append(fault)
            }
        }
        return AuthoringBasesResult(
            mainlines: ResolvedMainlines(workingRepos: entries, specSource: context.mainlines.specSource),
            records: records.sorted { $0.repository < $1.repository }, faults: faults
        )
    }

    /// The bases a selected Feature was authored against, from its `feature_base` record — what the build Act
    /// resolves a Card against (roadmap P23.3). A repository with no record keeps the Act's mainline.
    public static func fromRecord(
        journal: JournalStore, featureID: Int64, context: ActContext
    ) throws -> AuthoringBasesResult {
        let records = try journal.featureBases(featureID: featureID)
        var entries = context.mainlines.workingRepos
        for record in records {
            let repo = context.repositories?.workingRepo(named: record.repository)
            entries[record.repository] = ResolvedMainline(
                repository: record.repository,
                defaultBranch: context.mainlines[record.repository]?.defaultBranch ?? repo?.defaultBranch ?? "main",
                ref: record.baseRef, commit: record.baseCommit
            )
        }
        return AuthoringBasesResult(
            mainlines: ResolvedMainlines(workingRepos: entries, specSource: context.mainlines.specSource),
            records: records, faults: []
        )
    }

    private struct ResolvedBase {
        let ref: String
        let commit: String
    }

    /// `C_last`: the pin, else the remote-tracking Feature Branch, and never a commit other than the recorded one.
    private static func resolve(
        _ base: EffectiveBase, in repo: Repo, git: GitRunner
    ) async -> Result<ResolvedBase, AuthoringBaseFault> {
        let path = (repo.path as NSString).expandingTildeInPath
        let pinRef = LandedTipPin.ref(for: base.branch)
        var resolvedRef: String?
        var resolvedCommit: String?

        if let pinCommit = await LandedTipPin(git: git).pinnedCommit(branch: base.branch, repositoryPath: path) {
            resolvedRef = pinRef
            resolvedCommit = pinCommit
        } else {
            let originRef = "refs/remotes/origin/\(base.branch.name)"
            let result = await git.run([
                "-C", path, "rev-parse", "--verify", "--quiet", "\(originRef)^{commit}"
            ])
            let sha = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.isSuccess && !sha.isEmpty {
                resolvedRef = originRef
                resolvedCommit = sha
            }
        }
        guard let ref = resolvedRef, let commit = resolvedCommit else {
            return .failure(.unresolved(
                repository: repo.name, branch: base.branch.name, featureIssueID: base.featureIssueID
            ))
        }
        if let recorded = base.landedCommit, recorded != commit {
            return .failure(.commitMismatch(
                repository: repo.name, branch: base.branch.name, featureIssueID: base.featureIssueID,
                resolved: commit, recorded: recorded
            ))
        }
        return .success(ResolvedBase(ref: ref, commit: commit))
    }
}

extension AuthoringBaseFault: Error {}

extension ActContext {
    /// This context with `bases` in place of the mainlines, for the author Act's selection call only (roadmap
    /// P23.2): selection, breakdown, transcription and the authoring-time checks read `effective_base(R)`, and
    /// the authoring transaction records `bases.records` with the Feature.
    public func authoring(against bases: AuthoringBasesResult) -> ActContext {
        ActContext(
            act: act, mode: mode, trigger: trigger, runID: runID, journal: journal, night: night, outbox: outbox,
            nightCard: nightCard, board: board, mainlines: bases.mainlines, workspace: workspace,
            repositories: repositories, operatorIdentity: operatorIdentity, featureBases: bases.records
        )
    }
}
