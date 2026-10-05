import Domain
import Journal
import Repositories

/// The land Act's concrete local merge test. It evaluates one Repo Lane against the mainline snapshot
/// resolved at Act start, records conflicts in the Journal, and never turns a conflict into a lane fault.
public struct FeatureBranchLaneMergeTest: LaneMergeTesting, Sendable {
    public let tester: MergeTester

    public init(tester: MergeTester = MergeTester()) {
        self.tester = tester
    }

    public func test(_ context: LandActLaneContext) async throws -> MergeTestOutcome {
        let result = try await evaluate(context)
        let stamp = "as of Night \(context.act.night.nightStart)"
        let detail = "\(result.detail ?? "untestable") (\(stamp))"
        if let outbox = context.act.outbox {
            let repository = context.lane.repository
            let prefix = "Mainline merge test for `\(repository)`: "
            let marker = result.conflict ? "[conflict: \(repository)] " : ""
            let line = prefix + marker + detail
            let hash = ManagedBlockFence.sha256(line)
            // Accept the intent before any board read; delivery reads the current block and preserves
            // other lanes' reports even when this write was deferred or replayed after interruption.
            _ = try outbox.accept(OutboxWrite(
                key: "feature-merge:\(context.feature.issueID):\(context.act.runID):\(hash)",
                write: .updateManagedBlockLine(
                    issue: BoardObjectID(rawValue: context.feature.issueID), prefix: prefix, line: line
                )
            ))
            _ = try await outbox.deliverPending()
        }
        return MergeTestOutcome(
            conflict: result.conflict, detail: detail, untestable: result.untestable, paths: result.paths,
            mainlineRef: result.mainlineRef, mainlineCommit: result.mainlineCommit
        )
    }

    private func evaluate(_ context: LandActLaneContext) async throws -> MergeTestOutcome {
        let resolved = try context.act.journal.resolvedFeatureBranch(
            feature: context.feature, repository: context.lane.repository
        )
        guard let branch = resolved else {
            return MergeTestOutcome(
                conflict: false,
                detail: "untestable: the Feature has no recorded Feature Branch",
                untestable: true
            )
        }
        guard let repository = context.act.repositories?.workingRepo(named: context.lane.repository) else {
            return MergeTestOutcome(
                conflict: false,
                detail: "untestable: no repository named \"\(context.lane.repository)\" is configured",
                untestable: true
            )
        }
        // The Act's resolved snapshot is required. Falling back to a mutable local branch would make a
        // clean result refer to a different mainline than the sequencing gate read.
        guard let mainline = context.act.mainlines[repository] else {
            return MergeTestOutcome(
                conflict: false,
                detail: "untestable: no mainline snapshot was resolved for \"\(repository.name)\"",
                untestable: true
            )
        }
        guard mainline.ref == "refs/remotes/origin/\(mainline.defaultBranch)" else {
            return MergeTestOutcome(
                conflict: false,
                detail: "untestable: mainline snapshot \"\(mainline.ref)\" is not the refreshed remote-tracking ref",
                untestable: true
            )
        }

        let result = await tester.testMerge(branch: branch, in: repository, mainline: mainline)
        return try record(result, repository: repository, mainline: mainline, context: context)
    }

    private func record(
        _ result: RepoMergeResult,
        repository: Repo,
        mainline: ResolvedMainline,
        context: LandActLaneContext
    ) throws -> MergeTestOutcome {
        switch result.verdict {
        case .clean:
            return MergeTestOutcome(
                conflict: false,
                detail: "clean against \(mainline.ref) at \(mainline.commit); " +
                    "clean is not a claim that merging is safe; the cached remote-tracking ref may be stale",
                mainlineRef: mainline.ref,
                mainlineCommit: mainline.commit
            )
        case .conflicting(let paths):
            try context.act.journal.append(
                .mainlineConflictDetected(
                    featureIssueID: context.feature.issueID,
                    repository: repository.name,
                    paths: paths
                ),
                act: context.act.act,
                runID: context.act.runID,
                nightID: context.act.night.id
            )
            return MergeTestOutcome(
                conflict: true,
                detail: "Mainline Conflict in \(repository.name): \(paths.joined(separator: ", ")) " +
                    "(branch \(result.branchCommit ?? "unresolved"), against \(mainline.ref) " +
                    "at \(mainline.commit)); reported only",
                paths: paths,
                mainlineRef: mainline.ref,
                mainlineCommit: mainline.commit
            )
        case .untestable(let reason):
            return MergeTestOutcome(
                conflict: false,
                detail: "untestable: \(reason)",
                untestable: true
            )
        }
    }
}
