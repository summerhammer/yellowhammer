import Domain
import Foundation
import Journal

// The Unmerged Feature Stack U, the in-flight Feature's bases, and the stack-full skip, read from the one store
// the read is handed. Nothing about U is cached: it is derived from the Journal on every read.

extension PulseSnapshot {
    /// U, bottom of the stack first, as `JournalStore.unmergedFeatureStack()` orders it. `night` is the Night the
    /// Pulse shows: a Feature is `landedTonight` when its Cycle's `cycleLanded` event is stamped with it.
    static func unmergedFeatures(_ journal: JournalStore, night: NightRecord?) throws -> UnmergedFeatureStack {
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
