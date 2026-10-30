import Domain
import Foundation
import Journal
import Repositories

/// The release gate for Repo Dependencies (feature-authoring/select-the-next-feature, `#release-gate` and
/// `#effective-base`): which consumer Repos the author Act must not select a Feature for tonight, because their
/// producer has a Feature in the Unmerged Feature Stack U without an Observed Merge there, or because they read
/// a producer by tag and no release of the producer contains the producer's latest Feature yet.
public protocol ReleaseGate: Sendable {
    func heldConsumers(_ context: ActContext) async throws -> [HeldConsumer]
}

/// Opens a producer when an Observed Release is recorded for its latest pushed Feature, finding and recording
/// one when a release-shaped tag of the producer contains that Feature's work. Pure local git, run once per
/// author Act before selection; the tags are as the Act-start tag fetch left them, so a tag the fetch could not
/// bring is absent and the gate stays closed. It never reads a consumer's version requirement. A `mainline` edge
/// adds nothing beyond the Observed Merge its producer's Feature in U awaits (roadmap P23.2).
public struct ObservedReleaseGate: ReleaseGate {
    public let tags: ReleaseTagReader
    public let mergeTester: MergeTester

    public init(tags: ReleaseTagReader = ReleaseTagReader(), mergeTester: MergeTester = MergeTester()) {
        self.tags = tags
        self.mergeTester = mergeTester
    }

    public func heldConsumers(_ context: ActContext) async throws -> [HeldConsumer] {
        guard let repositories = context.repositories else { return [] }
        // A consumer of a producer with a Feature in U is held until that Feature's Observed Merge, whichever way
        // it reads the producer (roadmap P23.2; `#effective-base`); only then does a `tag` edge wait for a release.
        let awaitingMerge = try Self.awaitingMerge(repositories, stack: context.journal.unmergedFeatureStack())
        let mergeHeld = Set(awaitingMerge.map { [$0.consumer, $0.producer] })
        var consumersByProducer: [String: [String]] = [:]
        for repo in repositories.workingRepos {
            for edge in repo.consumes where edge.via == .tag && !mergeHeld.contains([repo.name, edge.producer]) {
                consumersByProducer[edge.producer, default: []].append(repo.name)
            }
        }
        var held = awaitingMerge
        for producer in consumersByProducer.keys.sorted() {
            guard let repo = repositories.workingRepo(named: producer),
                  let feature = try context.journal.latestFeaturePushed(in: producer),
                  try await !isOpen(producer: repo, feature: feature, context: context)
            else { continue }
            for consumer in consumersByProducer[producer, default: []] {
                held.append(HeldConsumer(
                    consumer: consumer, producer: producer, producerFeature: feature.displayIdentifier,
                    producerFeatureIssueID: feature.issueID, hold: .awaitingRelease
                ))
            }
        }
        return held.sorted { ($0.consumer, $0.producer) < ($1.consumer, $1.producer) }
    }

    /// Every declared edge, `mainline` or `tag`, whose producer has a Feature in U with no Observed Merge in the
    /// producer yet: held on the most recent such Feature. A Feature merged in the producer but not elsewhere
    /// releases the producer's consumers.
    static func awaitingMerge(_ repositories: ProjectRepositories, stack: [UnmergedFeature]) -> [HeldConsumer] {
        repositories.workingRepos.flatMap { consumer in
            consumer.consumes.compactMap { edge -> HeldConsumer? in
                guard let member = stack.last(where: { $0.unmergedRepositories.contains(edge.producer) }) else {
                    return nil
                }
                return HeldConsumer(
                    consumer: consumer.name, producer: edge.producer,
                    producerFeature: member.feature.displayIdentifier,
                    producerFeatureIssueID: member.feature.issueID, hold: .awaitingMerge
                )
            }
        }
    }

    /// Whether `feature` has an Observed Release in `producer`: read from the record when there is one, else
    /// found now and recorded.
    private func isOpen(producer: Repo, feature: FeatureRecord, context: ActContext) async throws -> Bool {
        let journal = context.journal
        if try journal.releases(featureID: feature.id)[producer.name] != nil { return true }
        let path = (producer.path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else { return false }
        for tag in await tags.releaseTags(in: path) {
            guard try await contains(feature, producer: producer, tag: tag, journal: journal) else { continue }
            try journal.recordRelease(
                featureID: feature.id, repository: producer.name, tagName: tag.name, tagCommit: tag.commit
            )
            try journal.append(
                .observedReleaseRecorded(
                    featureIssueID: feature.issueID, repository: producer.name,
                    tagName: tag.name, tagCommit: tag.commit
                ),
                act: context.act, runID: context.runID, nightID: context.night.id
            )
            return true
        }
        return false
    }

    /// Whether `tag` contains the Feature's work in `producer`: (A) the landing commit of its Observed Merge —
    /// where the change entered mainline — is an ancestor of the tag (OQ190 item 26), or (B) the Pushed Tip is,
    /// or the content test finds it in the tag's history (a squash or rebase merge): the merge test's ancestry
    /// and content tests read against the tag instead of mainline.
    private func contains(
        _ feature: FeatureRecord, producer: Repo, tag: (name: String, commit: String), journal: JournalStore
    ) async throws -> Bool {
        let path = (producer.path as NSString).expandingTildeInPath
        if let landing = try journal.landingCommits(featureID: feature.id)[producer.name],
           await tags.contains(landing, tag: tag.commit, in: path) {
            return true
        }
        let branch = try journal.featureBranches(featureID: feature.id)[producer.name]
        let recorded = try journal.pushedTips(featureID: feature.id)[producer.name]
        guard branch != nil || recorded != nil else { return false }
        let release = ResolvedMainline(
            repository: producer.name, defaultBranch: producer.defaultBranch ?? "main",
            ref: "refs/tags/\(tag.name)", commit: tag.commit
        )
        let result = await mergeTester.testContent(
            branch: branch?.name ?? "", recordedCommit: recorded, in: producer, mainline: release
        )
        if let tip = result.branchCommit, await tags.contains(tip, tag: tag.commit, in: path) { return true }
        return result.isContentMerged
    }
}
