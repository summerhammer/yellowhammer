import Domain
import Foundation
import Journal
import Repositories

// The predecessor gate's pull request read (spec: feature-authoring/select-the-next-feature, #pull-request-read;
// OQ190 items 14, 16, 27 and 28; issue #717): once per pass, the pull request of every pushed repository of the
// Feature under test is read, including repositories that already have an Observed Merge, until it reads merged. A
// pull request found by head branch counts only when it carries the tested tip (M1 on PR #723, ruled by the Operator
// 2026-10-31): "merged is final" holds for that one pull request, not for whichever one the branch last showed.
// Each successful read records the pull request's last observed state on its `pull_request` row; a failed read
// records `PullRequestReadFailed` and leaves the last state. A read by head branch that finds more than one pull
// request records `MultiplePullRequestsObserved` (#714). The same read then serves the pull request test
// (PredecessorAncestryGate+PullRequestTest.swift) for the repositories with no Observed Merge yet, so a pull request
// is read at most once per Feature per pass. The state never changes a recorded Observed Merge.

extension PredecessorAncestryGate {
    /// What the pass's pull request read found in one repository.
    enum PullRequestReading {
        /// The read was made: the pull request the test uses among those it found
        /// (``pullRequestUnderTest(_:selector:tip:path:)``), nil when none applies.
        case read(underTest: ObservedPullRequest?)
        /// Not read again: the last observed state is merged, which is final for that pull request, and it still
        /// carries the tested tip (``recordedMergeStands(_:selector:tip:path:)``). The merge commit that read recorded
        /// stands for it.
        case recordedMerge(mergeCommit: String?)
        /// The read could not be made. `PullRequestReadFailed` is recorded.
        case failed
    }

    /// Reads the pull request of each of `pushedRepositories` once, records what each successful read observed, and
    /// returns what was found, keyed by repository. A repository is not read, and is absent from the result, where
    /// there is no Publication Port, where the Project does not configure it or its `origin` names no GitHub
    /// repository, or where neither a recorded URL nor a recorded Feature Branch says which pull request to read.
    /// None of these throws, so a Feature whose repositories all have their Observed Merge never fails on them.
    func readPullRequests(
        feature: FeatureRecord, pushedRepositories: [String], context: ActContext
    ) async throws -> [String: PullRequestReading] {
        guard let publication, !pushedRepositories.isEmpty else { return [:] }
        let journal = context.journal
        let recorded = try journal.pullRequests(featureID: feature.id)
        let branches = try journal.featureBranches(featureID: feature.id)
        let pushedTips = try journal.pushedTips(featureID: feature.id)

        var readings: [String: PullRequestReading] = [:]
        for repository in pushedRepositories {
            let selector = Self.pullRequestSelector(recorded: recorded[repository], branch: branches[repository])
            let path = context.repositories?.workingRepo(named: repository)
                .map { ($0.path as NSString).expandingTildeInPath }
            // The tested tip (#tested-tip): the Pushed Tip, else the Feature Branch, which git resolves by name.
            let tip = pushedTips[repository] ?? branches[repository]?.name
            if let record = recorded[repository], record.observedState == .merged,
               await recordedMergeStands(record, selector: selector, tip: tip, path: path) {
                readings[repository] = .recordedMerge(mergeCommit: record.mergeCommit)
                continue
            }
            guard let path, let slug = await slugResolver.resolve(path: path), let selector else { continue }

            let read: [ObservedPullRequest]
            do {
                read = try await publication.readPullRequests(
                    PullRequestQuery(owner: slug.owner, repository: slug.repository, selector: selector)
                )
            } catch {
                try recordOncePerPass(
                    .pullRequestReadFailed(repository: repository, reason: error.reason), context: context
                )
                readings[repository] = .failed
                continue
            }
            let underTest = await pullRequestUnderTest(read, selector: selector, tip: tip, path: path)
            readings[repository] = .read(underTest: underTest)
            if case .headBranch(let branch) = selector, read.count > 1 {
                try recordOncePerPass(
                    .multiplePullRequestsObserved(
                        repository: repository, branch: branch, numbers: read.map(\.number).sorted()
                    ),
                    context: context
                )
            }
            if let underTest {
                try journal.recordObservedPullRequest(
                    featureID: feature.id, repository: repository, observed: underTest, runID: context.runID
                )
            }
        }
        return readings
    }

    /// Which pull request to read (OQ190 item 27): the one whose URL is recorded, by its number; where no URL was
    /// recorded (Code Hosting answered that one already existed, or none was recorded at all), the pull requests
    /// whose head is the Feature Branch. Nil when neither is known.
    static func pullRequestSelector(
        recorded: PullRequestRecord?, branch: FeatureBranch?
    ) -> PullRequestQuery.Selector? {
        if let number = PullRequestStackNotice.pullRequestNumber(fromURL: recorded?.url) {
            return .number(number)
        }
        guard let name = branch?.name, !name.isEmpty else { return nil }
        return .headBranch(name)
    }

    /// The pull request the test uses and the read records, among those `read` found. By number, the one found: it is
    /// the one the land Act opened. By head branch (OQ190 item 27, narrowed for M1), the one whose head is the tested
    /// tip; else a merged one whose head descends from the tip in this clone, as a fix-up the Operator pushed after
    /// the land and then merged does; else, when the read found only that one pull request, merged, and its head is
    /// not in this clone, that one, because a fix-up made on Code Hosting is never fetched. A merged pull request
    /// whose head this clone has but that does not carry the tip is never used: it holds older work. Nil when none
    /// applies, which leaves the repository to the content test.
    func pullRequestUnderTest(
        _ read: [ObservedPullRequest], selector: PullRequestQuery.Selector, tip: String?, path: String
    ) async -> ObservedPullRequest? {
        if case .number = selector { return read.first }
        guard let tip else { return nil }
        if let atTip = read.first(where: { $0.headCommit == tip }) { return atTip }
        for pullRequest in read where pullRequest.state == .merged {
            if await headCarries(pullRequest.headCommit, tip: tip, path: path) == true { return pullRequest }
        }
        if read.count == 1, let sole = read.first, sole.state == .merged,
           await headCarries(sole.headCommit, tip: tip, path: path) == nil {
            return sole
        }
        return nil
    }

    /// Whether a merged state an earlier read recorded still stands without a read. By number it does: merged is
    /// final for the pull request the land Act opened. By head branch it does only while the recorded head is the
    /// tested tip or descends from it in this clone; otherwise the branch is read again this pass, so a newer pull
    /// request can be observed and an older one never stands for work pushed after it.
    func recordedMergeStands(
        _ record: PullRequestRecord, selector: PullRequestQuery.Selector?, tip: String?, path: String?
    ) async -> Bool {
        guard case .headBranch = selector else { return true }
        guard let tip, let path, let head = record.headCommit else { return false }
        if head == tip { return true }
        return await headCarries(head, tip: tip, path: path) == true
    }

    /// Whether a pull request's `head` carries `tip`, checked locally (`git merge-base --is-ancestor`): true when
    /// `tip` is an ancestor of it, false when it is not, nil when this clone does not have `head`.
    private func headCarries(_ head: String, tip: String, path: String) async -> Bool? {
        guard await ancestryTester.hasCommit(head, in: path) else { return nil }
        return await ancestryTester.isAncestor(ancestorCommitOrRef: tip, of: head, in: path)
    }

    /// Records `event` at most once in this pass (OQ190 item 28): several Features in U can read the same
    /// repository. `PullRequestReadFailed` is keyed by its repository, `MultiplePullRequestsObserved` by its
    /// repository and branch. Neither is a Failure Notice or a halt.
    private func recordOncePerPass(_ event: JournalEvent, context: ActContext) throws {
        // Only this pass's events of the type, filtered in SQL: every earlier Night's are never decoded.
        let alreadyRecorded = try context.journal.events(runID: context.runID, ofTypes: [event.type]).contains {
            Self.samePassKey($0.event, event)
        }
        guard !alreadyRecorded else { return }
        try context.journal.append(event, act: context.act, runID: context.runID, nightID: context.night.id)
    }

    private static func samePassKey(_ recorded: JournalEvent, _ event: JournalEvent) -> Bool {
        switch (recorded, event) {
        case (.pullRequestReadFailed(let one, _), .pullRequestReadFailed(let other, _)):
            one == other
        case (.multiplePullRequestsObserved(let one, let oneBranch, _),
              .multiplePullRequestsObserved(let other, let otherBranch, _)):
            one == other && oneBranch == otherBranch
        default:
            false
        }
    }
}
