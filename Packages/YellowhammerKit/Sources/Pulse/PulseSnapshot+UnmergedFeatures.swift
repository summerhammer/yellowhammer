import Domain
import Foundation
import Journal

// The Unmerged Feature Stack U, the in-flight Feature's bases, and the stack-full skip, read from the one store
// the read is handed. Nothing about U is cached: it is derived from the Journal on every read.

extension PulseSnapshot {
    /// U, bottom of the stack first, as `JournalStore.unmergedFeatureStack()` orders it. `night` is the Night the
    /// Pulse shows: a Feature is `landedTonight` when its Cycle's `cycleLanded` event is stamped with it.
    static func unmergedFeatures(_ journal: JournalStore, night: NightRecord?) throws -> UnmergedFeatureStack {
        let lastReadFailures = try lastPullRequestReadFailures(journal)
        let features = try journal.unmergedFeatureStack().map { member in
            let record = member.feature
            let pullRequests = try journal.pullRequests(featureID: record.id)
            let bases = try journal.featureBases(featureID: record.id)
            let landedNight = try journal.landedNightID(featureID: record.id)
            let repositories = try member.pushedRepositories.sorted().map { repo in
                AwaitingMergeRepository(
                    repo: repo,
                    merged: member.mergedRepositories.contains(repo),
                    branch: member.branches[repo]?.rawValue,
                    pullRequest: pullRequests[repo].flatMap(chip),
                    pullRequestObservation: pullRequests[repo].flatMap { record in
                        observation(record, lastReadFailure: lastReadFailures[repo])
                    },
                    stackedOn: try stackedOnIdentifier(
                        journal, base: bases.first { $0.repository == repo }
                    )
                )
            }
            return AwaitingMergeFeature(
                id: record.issueID,
                issueIDForDisplay: record.issueIDForDisplay ?? record.issueKey,
                link: LinearIssueLink.link(key: record.issueIDForDisplay ?? record.issueKey, url: record.issueURL),
                landedTonight: night != nil && landedNight == night?.id,
                repositories: repositories
            )
        }
        return UnmergedFeatureStack(features: features)
    }

    /// The pull request's last observed state and its time (app/land-on-the-sidebar-and-pulse `#pull-request-state`;
    /// OQ190 items 17 and 18); nil when no read has succeeded, a failed one included: a state never observed shows
    /// none. The latest read failed when a `PullRequestReadFailed` for the repository comes after the observation.
    /// A pull request last observed merged is not read again, so no later failure is its own.
    ///
    /// `PullRequestReadFailed` names a repository, not a Feature, and is recorded once per pass: where two Features
    /// in U share a repository and only one's read failed in a pass, both read as failed until the next good read.
    static func observation(_ record: PullRequestRecord, lastReadFailure: Date?) -> PullRequestObservation? {
        guard let state = record.observedState, let observedAt = record.observedAt else { return nil }
        let failed = state != .merged && lastReadFailure.map { $0 > observedAt } == true
        return PullRequestObservation(state: state, observedAt: observedAt, latestReadFailed: failed)
    }

    /// When each repository's pull request read last failed, from every Night: a Feature can wait in U for many.
    private static func lastPullRequestReadFailures(_ journal: JournalStore) throws -> [String: Date] {
        var result: [String: Date] = [:]
        for record in try journal.events(ofType: .pullRequestReadFailed) {
            guard case .pullRequestReadFailed(let repository, _) = record.event else { continue }
            result[repository] = max(result[repository] ?? record.occurredAt, record.occurredAt)
        }
        return result
    }

    /// Per repository, the display identifier of the Feature in U that `featureID`'s recorded base stacks on;
    /// empty when every recorded base is mainline.
    static func stackedOn(_ journal: JournalStore, featureID: Int64) throws -> [String: String] {
        var result: [String: String] = [:]
        for base in try journal.featureBases(featureID: featureID) {
            if let identifier = try stackedOnIdentifier(journal, base: base) {
                result[base.repository] = identifier
            }
        }
        return result
    }

    private static func stackedOnIdentifier(_ journal: JournalStore, base: FeatureBaseRecord?) throws -> String? {
        guard let stackedOnID = base?.stackedOnFeatureID, let record = try journal.feature(id: stackedOnID) else {
            return nil
        }
        return displayIdentifier(record)
    }

    /// What a person reads for a Feature; never the Journal's row id.
    static func displayIdentifier(_ record: FeatureRecord) -> String {
        record.issueIDForDisplay ?? record.issueKey ?? record.issueID
    }

    /// The Night's author firings that authored nothing because U was full: the latest skip's identifiers, Bound
    /// and time, and how many such firings there were. Nil when this Night has none; a skip recorded under another
    /// Night never counts.
    static func stackFullSkip(nightEvents: [JournalEventRecord]) -> StackFullSkip? {
        let skips = nightEvents.filter { $0.type == .authoringSkippedUnmergedStackFull }
        guard let latest = skips.last,
            case .authoringSkippedUnmergedStackFull(let entries, let bound) = latest.event
        else { return nil }
        return StackFullSkip(
            features: entries.map(\.identifier), unmergedFeaturesMax: bound, at: latest.occurredAt, count: skips.count
        )
    }
}
