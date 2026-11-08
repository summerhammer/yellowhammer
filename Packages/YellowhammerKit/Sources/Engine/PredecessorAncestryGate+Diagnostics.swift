import Domain
import Journal
import Repositories

// Diagnostics never substitute for an Observed Merge. In particular a merged pull request into a
// lower branch is not proof that its immutable Pushed Tip reached mainline (#741, OQ190 items 9, 23–25).
extension PredecessorAncestryGate {
    func recordMergeTest(
        repository: String, test: String, result: String, commits: (tip: String?, mainline: String?), scope: TestScope,
        extra: [String: String] = [:]
    ) throws {
        var details = extra
        details["test"] = test
        details["result"] = result
        details["tested_tip"] = commits.tip ?? scope.tips[repository]?.recordedCommit ?? ""
        details["mainline_commit"] = commits.mainline ?? ""
        details["mainline_ref"] = details["mainline_ref"] ?? scope.context.mainlines[repository]?.ref ?? ""
        try scope.context.journal.append(
            .predecessorMergeTested(featureIssueID: scope.feature.issueID, repository: repository, details: details),
            act: scope.context.act, runID: scope.context.runID, nightID: scope.context.night.id
        )
    }

    func ancestryTestReason(_ result: RepoAncestryResult) -> String {
        guard result.branchCommit != nil else { return "tip_unreadable" }
        guard result.mainlineCommit != nil else { return "mainline_unreadable" }
        guard result.isAncestor else { return "not_ancestor" }
        return result.landingCommit == nil ? "ancestor_landing_commit_unreadable" : "ancestor"
    }

    func pullRequestTestReason(_ reading: PullRequestReading?, merged: Bool) -> String {
        if merged { return "merge_commit_in_mainline" }
        switch reading {
        case .failed: return "read_failed"
        case nil: return "read_unavailable"
        case .read(nil): return "no_applicable_pull_request"
        case .read(let request):
            guard request?.state == .merged else { return "pull_request_not_merged" }
            return request?.mergeCommit == nil ? "merge_commit_missing" : "merge_commit_not_in_mainline_or_unreadable"
        case .recordedMerge(let commit):
            return commit == nil ? "merge_commit_missing" : "merge_commit_not_in_mainline_or_unreadable"
        }
    }

    func recordContentTest(_ merge: RepoMergeResult, plan: ContentTestPlan, scope: TestScope) throws {
        var details: [String: String] = [
            "mainline_ref": merge.mainlineRef ?? "", "landing_commit": merge.landingCommit ?? ""
        ]
        let result: String
        switch plan {
        case .notRun(let reason): result = "not_run: " + reason
        case .fromForkPoint, .stacked:
            if merge.isContentMerged {
                result = "landing_observed"
            } else if merge.tipHasNetChange == false {
                result = "no_net_change"
            } else if merge.tipHasNetChange == nil {
                result = "net_change_unreadable"
            } else {
                // A failed history read can also leave no landing. Do not claim a negative proof.
                result = "landing_not_observed"
            }
        }
        if case .stacked(let anchor) = plan {
            details["recorded_base"] = anchor.recordedBase
            details["lower_landing_commit"] = anchor.lowerLandingCommit
        }
        switch merge.verdict {
        case .clean: details["head_merge"] = "clean"
        case .conflicting(let paths): details["head_merge"] = "conflicting: " + paths.joined(separator: ", ")
        case .untestable(let reason): details["head_merge"] = "untestable: " + reason
        }
        try recordMergeTest(
            repository: merge.repository, test: "content", result: result,
            commits: (merge.branchCommit, merge.mainlineCommit), scope: scope, extra: details
        )
    }
}
