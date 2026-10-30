import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
@testable import Journal
import Repositories
import Testing

// feature-authoring/select-the-next-feature, `#release-gate`: a consumer that reads a producer by tag is held
// until a release-shaped tag of the producer contains the producer's latest pushed Feature. Real git; the
// fixtures are PredecessorAncestryGateFixtures.swift's.

/// A producer repository `contracts` with a Feature Branch tip `T` merged into `main` by a merge commit `M`,
/// and a commit `X` after the merge, which a release tag can name.
private struct ProducerWorld: ~Copyable {
    let repo: GateGitFixture
    let base: String
    let tip: String
    let merge: String
    let after: String

    static func make() async throws -> ProducerWorld {
        let repo = GateGitFixture(name: "contracts")
        await repo.initRepo(defaultBranch: "main")
        let base = try await repo.commit(filename: "base.txt", message: "base")
        await repo.run(["checkout", "-b", "yh-feat"])
        let tip = try await repo.commit(filename: "feature.txt", content: "the feature", message: "feature")
        await repo.run(["checkout", "main"])
        await repo.run(["merge", "--no-ff", "-m", "merge feature", "yh-feat"])
        let merge = try #require(
            await repo.run(["rev-parse", "HEAD"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )
        let after = try await repo.commit(filename: "after.txt", message: "after the merge")
        return ProducerWorld(repo: repo, base: base, tip: tip, merge: merge, after: after)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private func repositories(producerPath: String, via: RepoDependencyVia = .tag) -> ProjectRepositories {
    ProjectRepositories(
        workingRepos: [
            Repo(
                name: "backend", path: "/nonexistent/backend", role: .backend,
                consumes: [RepoDependency(producer: "contracts", via: via)]
            ),
            Repo(name: "contracts", path: producerPath, role: .backend)
        ],
        specSource: SpecSource(path: "/nonexistent/spec")
    )
}

private func held(_ issueID: String = "FEAT-K") -> [HeldConsumer] {
    [HeldConsumer(
        consumer: "backend", producer: "contracts", producerFeature: issueID, producerFeatureIssueID: issueID,
        hold: .awaitingRelease
    )]
}

/// Feature K, archived, pushed in `contracts`: its tip recorded, and — unless `landed` is false — an Observed
/// Merge at `world.merge`.
@discardableResult
private func seedFeature(_ journal: JournalStore, world: borrowing ProducerWorld, landed: Bool = true) throws -> Int64 {
    let featureID = try insertGateFeature(
        journal, issueID: "FEAT-K", branch: "yh-feat", repositories: ["contracts"],
        pushedTips: ["contracts": world.tip]
    )
    if landed {
        try journal.recordLanding(
            featureID: featureID, repository: "contracts", landingCommit: world.merge,
            mainlineCommit: world.merge, evidence: .ancestry
        )
    }
    return featureID
}

private func heldConsumers(
    _ journal: JournalStore, producerPath: String, via: RepoDependencyVia = .tag
) async throws -> [HeldConsumer] {
    let (context, _) = try makeGateContext(journal, repositories: repositories(producerPath: producerPath, via: via))
    return try await ObservedReleaseGate().heldConsumers(context)
}

@Suite("Release gate for tag Repo Dependencies")
struct ReleaseGateTests {
    @Test("With no release tag the consumer is held, naming the producer's Feature")
    func noTagHoldsTheConsumer() async throws {
        let world = try await ProducerWorld.make()
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        try seedFeature(journal, world: world)

        #expect(try await heldConsumers(journal, producerPath: world.repo.path) == held())
    }

    @Test("A release tag after the merge opens the gate, is recorded once, and stays open when the tag is deleted")
    func releaseTagOpensAndIsRecorded() async throws {
        let world = try await ProducerWorld.make()
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let featureID = try seedFeature(journal, world: world)
        await world.repo.run(["tag", "v1.0.0", world.after])
        let (context, _) = try makeGateContext(journal, repositories: repositories(producerPath: world.repo.path))
        let gate = ObservedReleaseGate()

        #expect(try await gate.heldConsumers(context).isEmpty)
        #expect(try journal.releases(featureID: featureID) == [
            "contracts": ObservedRelease(tagName: "v1.0.0", tagCommit: world.after)
        ])
        #expect(try journal.events(ofType: .observedReleaseRecorded).map(\.event) == [
            .observedReleaseRecorded(
                featureIssueID: "FEAT-K", repository: "contracts", tagName: "v1.0.0", tagCommit: world.after
            )
        ])

        await world.repo.run(["tag", "-d", "v1.0.0"])
        #expect(try await gate.heldConsumers(context).isEmpty)
        #expect(try journal.events(ofType: .observedReleaseRecorded).count == 1)
    }

    @Test("A tag that predates the merge does not open the gate")
    func tagBeforeTheMergeDoesNotOpen() async throws {
        let world = try await ProducerWorld.make()
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        try seedFeature(journal, world: world)
        await world.repo.run(["tag", "v0.9.0", world.base])

        #expect(try await heldConsumers(journal, producerPath: world.repo.path) == held())
    }

    // OQ190 item 26: test (A) reads the landing commit, not the mainline commit the merge was first observed at.
    // The recorded Pushed Tip is one the repository lacks, so test (B) cannot pass and (A) alone decides.
    @Test("Test (A): a tag cut after the landing commit opens, though the merge was observed at a later commit")
    func tagAfterTheLandingCommitOpens() async throws {
        let world = try await ProducerWorld.make()
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let featureID = try insertGateFeature(
            journal, issueID: "FEAT-K", branch: "yh-feat", repositories: ["contracts"],
            pushedTips: ["contracts": String(repeating: "ab", count: 20)]
        )
        await world.repo.run(["tag", "v1.0.0", world.after])
        let observedAt = try await world.repo.commit(filename: "later.txt", message: "after the tag")
        try journal.recordLanding(
            featureID: featureID, repository: "contracts", landingCommit: world.merge, mainlineCommit: observedAt,
            evidence: .ancestry
        )

        #expect(try await heldConsumers(journal, producerPath: world.repo.path).isEmpty)
        #expect(try journal.releases(featureID: featureID)["contracts"]?.tagName == "v1.0.0")
    }

    @Test("Test (A): a tag cut before the landing commit does not open")
    func tagBeforeTheLandingCommitDoesNotOpen() async throws {
        let world = try await ProducerWorld.make()
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let featureID = try insertGateFeature(
            journal, issueID: "FEAT-K", branch: "yh-feat", repositories: ["contracts"],
            pushedTips: ["contracts": String(repeating: "ab", count: 20)]
        )
        await world.repo.run(["tag", "v0.9.0", world.base])
        try journal.recordLanding(
            featureID: featureID, repository: "contracts", landingCommit: world.merge, mainlineCommit: world.after,
            evidence: .ancestry
        )

        #expect(try await heldConsumers(journal, producerPath: world.repo.path) == held())
        #expect(try journal.releases(featureID: featureID).isEmpty)
    }

    @Test("Test (B): a squash found in the tag's history opens, though the tag's head changed the same lines")
    func squashInTheTagHistoryOpens() async throws {
        let repo = GateGitFixture(name: "contracts-squash-history")
        await repo.initRepo(defaultBranch: "main")
        try await repo.commit(filename: "feature.txt", content: "base\n", message: "base")
        await repo.run(["checkout", "-b", "yh-feat"])
        let tip = try await repo.commit(filename: "feature.txt", content: "the feature\n", message: "feature")
        await repo.run(["checkout", "main"])
        await repo.run(["merge", "--squash", "yh-feat"])
        await repo.run(["commit", "-m", "feature (squashed)"])
        let release = try await repo.commit(filename: "feature.txt", content: "rewritten\n", message: "rewrite")
        await repo.run(["tag", "v1.0.0", release])
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let featureID = try insertGateFeature(
            journal, issueID: "FEAT-K", branch: "yh-feat", repositories: ["contracts"],
            pushedTips: ["contracts": tip]
        )
        // Observed past the tag, so test (A) cannot pass and (B) alone decides.
        let later = try await repo.commit(filename: "later.txt", message: "after the tag")
        try journal.recordLanding(
            featureID: featureID, repository: "contracts", landingCommit: later, mainlineCommit: later,
            evidence: .content
        )

        #expect(try await heldConsumers(journal, producerPath: repo.path).isEmpty)
    }

    @Test("A pre-release tag is not a release")
    func preReleaseTagDoesNotOpen() async throws {
        let world = try await ProducerWorld.make()
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        try seedFeature(journal, world: world)
        await world.repo.run(["tag", "v1.0.0-rc.1", world.after])

        #expect(try await heldConsumers(journal, producerPath: world.repo.path) == held())
    }

    @Test("A tag without the v prefix counts")
    func tagWithoutPrefixCounts() async throws {
        let world = try await ProducerWorld.make()
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let featureID = try seedFeature(journal, world: world)
        await world.repo.run(["tag", "1.0.0", world.after])

        #expect(try await heldConsumers(journal, producerPath: world.repo.path).isEmpty)
        #expect(try journal.releases(featureID: featureID)["contracts"]?.tagName == "1.0.0")
    }

    @Test("An annotated tag is read at the commit it peels to")
    func annotatedTagUsesThePeeledCommit() async throws {
        let world = try await ProducerWorld.make()
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let featureID = try seedFeature(journal, world: world)
        await world.repo.run(["tag", "-a", "v1.0.0", "-m", "release", world.after])

        #expect(try await heldConsumers(journal, producerPath: world.repo.path).isEmpty)
        #expect(try journal.releases(featureID: featureID)["contracts"]?.tagCommit == world.after)
    }

    @Test("With the Observed Merge recorded past the tag, a recorded tip that is an ancestor of the tag opens the gate")
    func tipAncestryOpensWithALandingPastTheTag() async throws {
        let world = try await ProducerWorld.make()
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let featureID = try seedFeature(journal, world: world, landed: false)
        await world.repo.run(["tag", "v1.0.0", world.after])
        // The merge was first observed at a mainline commit no release contains yet (roadmap P23.2: a producer
        // Feature with no Observed Merge holds its consumers on the merge, before any release is looked for).
        let later = try await world.repo.commit(filename: "later.txt", message: "after the tag")
        try journal.recordLanding(
            featureID: featureID, repository: "contracts", landingCommit: later,
            mainlineCommit: later, evidence: .content
        )

        #expect(try await heldConsumers(journal, producerPath: world.repo.path).isEmpty)
    }

    @Test("A squash-merged Feature is found by the content test against the tag")
    func squashMergedContentOpensTheGate() async throws {
        let repo = GateGitFixture(name: "contracts-squash")
        await repo.initRepo(defaultBranch: "main")
        try await repo.commit(filename: "base.txt", message: "base")
        await repo.run(["checkout", "-b", "yh-feat"])
        let tip = try await repo.commit(filename: "feature.txt", content: "the feature", message: "feature")
        await repo.run(["checkout", "main"])
        await repo.run(["merge", "--squash", "yh-feat"])
        await repo.run(["commit", "-m", "feature (squashed)"])
        let squash = try await repo.commit(filename: "after.txt", message: "after the squash")
        await repo.run(["tag", "v1.0.0", squash])
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let featureID = try insertGateFeature(
            journal, issueID: "FEAT-K", branch: "yh-feat", repositories: ["contracts"],
            pushedTips: ["contracts": tip]
        )
        let later = try await repo.commit(filename: "later.txt", message: "after the tag")
        try journal.recordLanding(
            featureID: featureID, repository: "contracts", landingCommit: later,
            mainlineCommit: later, evidence: .content
        )

        #expect(try await heldConsumers(journal, producerPath: repo.path).isEmpty)
        #expect(try journal.releases(featureID: featureID)["contracts"]?.tagName == "v1.0.0")
    }

    @Test("A mainline consumer of a producer with a Feature in U is held on its merge, and released once it lands")
    func mainlineConsumerOfAnUnmergedProducerIsHeld() async throws {
        let world = try await ProducerWorld.make()
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let featureID = try seedFeature(journal, world: world, landed: false)
        let (context, _) = try makeGateContext(
            journal, repositories: repositories(producerPath: world.repo.path, via: .mainline)
        )

        #expect(try await ObservedReleaseGate().heldConsumers(context) == [HeldConsumer(
            consumer: "backend", producer: "contracts", producerFeature: "FEAT-K", producerFeatureIssueID: "FEAT-K",
            hold: .awaitingMerge
        )])

        try journal.recordLanding(
            featureID: featureID, repository: "contracts", landingCommit: world.merge,
            mainlineCommit: world.merge, evidence: .ancestry
        )
        #expect(try await ObservedReleaseGate().heldConsumers(context).isEmpty)
    }

    @Test("A tag consumer of a producer with a Feature in U waits on the merge before any release, even if tagged")
    func tagConsumerOfAnUnmergedProducerWaitsOnTheMerge() async throws {
        let world = try await ProducerWorld.make()
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let featureID = try seedFeature(journal, world: world, landed: false)
        await world.repo.run(["tag", "v1.0.0", world.after])

        #expect(try await heldConsumers(journal, producerPath: world.repo.path) == [HeldConsumer(
            consumer: "backend", producer: "contracts", producerFeature: "FEAT-K", producerFeatureIssueID: "FEAT-K",
            hold: .awaitingMerge
        )])
        #expect(try journal.releases(featureID: featureID).isEmpty)
    }

    @Test("The Night Card line for a consumer held on its producer's merge names the Feature and the producer")
    func awaitingMergeNightCardLine() {
        let held = JournalEvent.authoringReleaseGateHeld(
            featureName: "Add login", consumer: "backend", producer: "contracts", producerFeatureIssueID: "FEAT-K",
            hold: .awaitingMerge
        )
        #expect(NightCardMaintenance.authoringLine(for: held) == """
            Authoring was skipped: backend consumes contracts, awaiting the Observed Merge of Feature `FEAT-K` in \
            contracts. Merge its pull request. A quiet Night, not a failure.
            """)
    }

    @Test("A mainline edge holds nothing")
    func mainlineEdgeHoldsNothing() async throws {
        let world = try await ProducerWorld.make()
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        try seedFeature(journal, world: world)

        #expect(try await heldConsumers(journal, producerPath: world.repo.path, via: .mainline).isEmpty)
    }

    @Test("A producer with no Feature that pushed there holds nothing")
    func producerWithoutAPushedFeatureHoldsNothing() async throws {
        let world = try await ProducerWorld.make()
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        try insertGateFeature(journal, issueID: "FEAT-OTHER", branch: "yh-other", repositories: ["backend"])

        #expect(try await heldConsumers(journal, producerPath: world.repo.path).isEmpty)
    }

    @Test("The Night Card line reads exactly, and an Observed Release is Journal-only")
    func nightCardLine() {
        let held = JournalEvent.authoringReleaseGateHeld(
            featureName: "Add login", consumer: "backend", producer: "contracts", producerFeatureIssueID: "FEAT-K",
                hold: .awaitingRelease
        )
        #expect(NightCardMaintenance.authoringLine(for: held) == """
            Authoring was skipped: backend reads contracts by tag, and no release of contracts contains \
            Feature `FEAT-K` yet. Cut a release of contracts that includes it. A quiet Night, not a failure.
            """)
        let recorded = JournalEvent.observedReleaseRecorded(
            featureIssueID: "FEAT-K", repository: "contracts", tagName: "v1.0.0", tagCommit: "abc"
        )
        #expect(NightCardMaintenance.authoringLine(for: recorded) == nil)
    }
}
