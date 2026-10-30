import Domain
import Foundation
import Journal
import Repositories

// The predecessor gate's pull request read (spec: feature-authoring/select-the-next-feature, #pull-request-read;
// OQ190 items 14, 16, 27 and 28; issue #717): once per pass, the pull request of every pushed repository of the
// Feature under test is read, including repositories that already have an Observed Merge, until it reads merged.
// Each successful read records the pull request's last observed state on its `pull_request` row; a failed read
// records `PullRequestReadFailed` and leaves the last state. A read by head branch that finds more than one pull
// request records `MultiplePullRequestsObserved` (#714). The same read then serves the pull request test
// (PredecessorAncestryGate+PullRequestTest.swift) for the repositories with no Observed Merge yet, so a pull request
// is read at most once per Feature per pass. The state never changes a recorded Observed Merge.

extension PredecessorAncestryGate {
    /// What the pass's pull request read found in one repository.
    enum PullRequestReading {
        /// The read was made: every pull request it found, none when the test does not apply. A read by number
        /// finds at most one.
        case read([ObservedPullRequest])
        /// Not read again: the last observed state is merged, which is final. The merge commit that read recorded
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
            if let record = recorded[repository], record.observedState == .merged {
                readings[repository] = .recordedMerge(mergeCommit: record.mergeCommit)
                continue
            }
            guard
                let repo = context.repositories?.workingRepo(named: repository),
                let slug = await slugResolver.resolve(path: (repo.path as NSString).expandingTildeInPath),
                let selector = Self.pullRequestSelector(recorded: recorded[repository], branch: branches[repository])
            else { continue }

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
            readings[repository] = .read(read)
            if case .headBranch(let branch) = selector, read.count > 1 {
                try recordOncePerPass(
                    .multiplePullRequestsObserved(
                        repository: repository, branch: branch, numbers: read.map(\.number).sorted()
                    ),
                    context: context
                )
            }
            if let observed = Self.pullRequestObserved(read, selector: selector, pushedTip: pushedTips[repository]) {
                try journal.recordObservedPullRequest(
                    featureID: feature.id, repository: repository, observed: observed, runID: context.runID
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

    /// The pull request whose state a read records: the one a read by number found; by head branch, the one the
    /// pull request test uses (``pullRequestUnderTest(_:pushedTip:)``). Nil records nothing.
    static func pullRequestObserved(
        _ read: [ObservedPullRequest], selector: PullRequestQuery.Selector, pushedTip: String?
    ) -> ObservedPullRequest? {
        switch selector {
        case .number:
            return read.first
        case .headBranch:
            return pullRequestUnderTest(read, pushedTip: pushedTip)
        }
    }

    /// The pull request the test uses among those read: the one whose head is the Pushed Tip, else a merged one
    /// (OQ190 item 27). A read by number has at most one.
    static func pullRequestUnderTest(_ read: [ObservedPullRequest], pushedTip: String?) -> ObservedPullRequest? {
        read.first { $0.headCommit == pushedTip } ?? read.first { $0.state == .merged }
    }

    /// Records `event` at most once in this pass (OQ190 item 28): several Features in U can read the same
    /// repository. `PullRequestReadFailed` is keyed by its repository, `MultiplePullRequestsObserved` by its
    /// repository and branch. Neither is a Failure Notice or a halt.
    private func recordOncePerPass(_ event: JournalEvent, context: ActContext) throws {
        let alreadyRecorded = try context.journal.events(ofType: event.type).contains { record in
            record.runID == context.runID && Self.samePassKey(record.event, event)
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
