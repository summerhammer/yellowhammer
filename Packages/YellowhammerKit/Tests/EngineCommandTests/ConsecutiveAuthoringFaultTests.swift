import Domain
@testable import Engine
import Foundation
@testable import Journal
import Testing

@Suite("Consecutive authoring faults")
struct ConsecutiveAuthoringFaultTests {
    @Test("Three walks are allowed; fourth selection halts without another breakdown or re-selection")
    func nextSelectionHalts() async throws {
        let rig = try await AuthoringRig(drafting: ScriptedBreakdown(
            FeatureBreakdown(definitionOfDone: [authoringClause("x")], cards: [])
        ))
        var context = try rig.context()
        let feature = try authoringSelection().name
        for count in 1...3 {
            #expect(try await rig.run(context) == .authoringRolledBack)
            #expect(try rig.journal.authoringFaultCount(feature: feature).count == count)
            context = try rig.context(previous: context)
        }
        #expect(try await rig.run(context) == .halted)
        #expect(rig.drafting.callCount == 3)
        #expect(rig.selector.callCount == 4)
        #expect(await rig.boards.writing.liveIssues.filter { $0.title == feature.rawValue }.count == 1)
        #expect(try NightSummary.exceptionLines(night: context.night, journal: rig.journal).contains {
            $0.contains("faulted on its last 3 authoring runs")
        })
    }

    @Test("One operation counts once; another Feature, another halt and an unavailable Route leave it alone")
    func countDeduplicatesAndPersists() async throws {
        let rig = try await AuthoringRig()
        let context = try rig.context()
        let feature = try authoringSelection().name
        for _ in 0..<2 {
            try rig.journal.recordAuthoringFault(
                feature: feature, reason: "rejected", operationKey: "one-walk",
                event: .featureBreakdownRejected(name: feature.rawValue, reason: "rejected"),
                nightID: context.night.id, act: context.act, runID: context.runID
            )
        }
        #expect(try rig.journal.authoringFaultCount(feature: feature).count == 1)
        #expect(try rig.journal.events(ofType: .featureBreakdownRejected).count == 1)
        let other = try #require(FeatureName(rawValue: "OTHER"))
        #expect(try rig.journal.authoringFaultCount(feature: other).count < 1)
        _ = try await AuthoringHalt.record(feature: feature, cause: .repositoriesUndetermined, context: context)
        let transaction = AuthoringTransaction(
            drafting: NoProducedBreakdown(), citations: FakeCitationResolver(),
            transcribing: FakeContractTranscriber(), provenance: FakeProvenanceTester()
        )
        #expect(try await transaction.author(authoringSelection(), context: context) == .authoringRolledBack)
        #expect(try rig.journal.authoringFaultCount(feature: feature).count == 1)
        let reopened = try rig.fixture.open()
        #expect(try reopened.authoringFaultCount(feature: feature).lastReason == "rejected")
    }

    @Test("Forced permanent Board refusal re-halts on the same Feature Card and does not reset")
    func forcedPermanentRefusalUsesExistingCard() async throws {
        let rig = try await AuthoringRig()
        var context = try rig.context()
        let feature = try authoringSelection().name
        try seedFaults(rig.journal, context: context, feature: feature)
        #expect(try await rig.run(context) == .halted)
        let initial = try #require(await rig.boards.writing.liveIssues.first { $0.title == feature.rawValue })
        try rig.journal.releaseActLease(runID: context.runID)
        context = try makeSelectionContext(
            rig.journal, repositories: selectionRepositories(), boards: rig.boards, trigger: .forcedForFeature(feature)
        ).context
        await rig.boards.writing.script(.refuse(.refused("permanent refusal")), for: "Backend two")
        #expect(try await rig.run(context) == .halted)
        let features = await rig.boards.writing.liveIssues.filter { $0.title == feature.rawValue }
        #expect(features.map(\.id) == [initial.id])
        #expect(features.first?.workflowState == initial.workflowState)
        #expect(try rig.journal.authoringFaultCount(feature: feature).count == 4)
        #expect(await rig.boards.writing.comments.filter { $0.issue == initial.id }.count == 2)
    }

    @Test("Forced rejected breakdown appends the repeat comment while an expired Feature stays Blocked")
    func forcedExpiredHalt() async throws {
        let rig = try await AuthoringRig(drafting: ScriptedBreakdown(
            FeatureBreakdown(definitionOfDone: [authoringClause("x")], cards: [])
        ))
        var context = try rig.context()
        let feature = try authoringSelection().name
        try seedFaults(rig.journal, context: context, feature: feature)
        #expect(try await rig.run(context) == .halted)
        let issue = try #require(await rig.boards.writing.liveIssues.first { $0.title == feature.rawValue })
        try rig.journal.write { db in
            try db.execute(sql: "UPDATE authoring_halt SET state = 'expired' WHERE feature_name = ?",
                           arguments: [feature.rawValue])
        }
        let scope = try await BoardStateScope.resolve(using: rig.boards.provisioning)
        let blocked = try scope.id(for: .blocked)
        _ = try await rig.boards.writing.updateIssue(issue.id, BoardIssueChange(workflowState: blocked))
        try rig.journal.releaseActLease(runID: context.runID)
        context = try makeSelectionContext(
            rig.journal, repositories: selectionRepositories(), boards: rig.boards, trigger: .forcedForFeature(feature)
        ).context
        #expect(try await rig.run(context) == .halted)
        #expect(try rig.journal.authoringFaultCount(feature: feature).count == 4)
        #expect(await rig.boards.writing.liveIssues.filter { $0.title == feature.rawValue }.map(\.id) == [issue.id])
        #expect(await rig.boards.writing.liveIssues.first { $0.id == issue.id }?.workflowState == blocked)
        #expect(await rig.boards.writing.comments.filter { $0.issue == issue.id }.count == 2)
    }

    @Test("A transient Board failure counts nothing; accepted transaction resets only its Feature")
    func transientAndAccepted() async throws {
        let rig = try await AuthoringRig()
        var context = try rig.context()
        let feature = try authoringSelection().name
        try seedFaults(rig.journal, context: context, feature: feature, count: 1)
        let other = try #require(FeatureName(rawValue: "OTHER"))
        try seedFaults(rig.journal, context: context, feature: other, count: 2)
        let cutoff = try #require(try rig.journal.events().last?.id)
        await rig.boards.writing.refuseNext(.rateLimited(retryAfter: nil, budget: nil))
        #expect(try await rig.run(context) == .authoringPending)
        #expect(try rig.journal.authoringFaultCount(feature: feature).count == 1)
        context = try rig.context(previous: context)
        #expect(try await rig.run(context) == .authored)
        #expect(try rig.journal.authoringFaultCount(feature: feature).count < 1)
        #expect(try rig.journal.authoringFaultCount(feature: other).count == 2)
        #expect(try rig.journal.authoringFaultCount(feature: feature, throughEventID: cutoff).count == 1)
        #expect(try NightSummary.boundProximity(night: context.night, journal: rig.journal, bounds: .init()).count == 7)
    }

    @Test("Reused Feature's authored clauses and human prose survive its next Roll-up rewrite")
    func reusedFeatureRetainsAuthoredProse() async throws {
        let rig = try await AuthoringRig()
        var context = try rig.context()
        let featureName = try authoringSelection().name
        try seedFaults(rig.journal, context: context, feature: featureName)
        #expect(try await rig.run(context) == .halted)
        let issue = try #require(await rig.boards.writing.liveIssues.first { $0.title == featureName.rawValue })
        let humanProse = "\n\nHuman decision context."
        _ = try await rig.boards.writing.updateIssue(
            issue.id, BoardIssueChange(description: (issue.description ?? "") + humanProse)
        )
        try rig.journal.releaseActLease(runID: context.runID)
        context = try makeSelectionContext(
            rig.journal, repositories: selectionRepositories(), boards: rig.boards,
            trigger: .forcedForFeature(featureName)
        ).context
        #expect(try await rig.run(context) == .authored)
        let (feature, cycleID) = try #require(try rig.journal.inFlightFeature())
        let outbox = try #require(context.outbox)
        _ = try await FeatureRollUpMaintenance(journal: rig.journal, outbox: outbox)
            .maintain(feature: feature, cycleID: cycleID)
        let description = try #require(await rig.boards.writing.liveIssues.first { $0.id == issue.id }?.description)
        #expect(description.contains("## Definition of done"))
        #expect(description.contains("resolvable/story"))
        #expect(description.contains(humanProse))
        let parts = try ManagedBlockFence.parts(of: description).get()
        #expect(!parts.block.contains("## Definition of done"))
        #expect(description.components(separatedBy: FeatureAuthoringProse.start).count == 2)
    }

    private func seedFaults(
        _ journal: JournalStore, context: ActContext, feature: FeatureName, count: Int = 3
    ) throws {
        for index in 0..<count {
            try journal.recordAuthoringFault(
                feature: feature, reason: "fault \(index)", operationKey: "seed-\(feature.rawValue)-\(index)",
                event: .featureBreakdownRejected(name: feature.rawValue, reason: "fault \(index)"),
                nightID: context.night.id, act: context.act, runID: context.runID
            )
        }
    }
}

private struct NoProducedBreakdown: FeatureBreakdownDrafting {
    func breakdown(
        for selection: SelectedFeature, mainlines: ResolvedMainlines, context: ActContext,
        accepting: @escaping BreakdownAcceptance
    ) async throws -> FeatureBreakdown {
        throw AuthoringDispatchFault(reason: "all Routes unavailable")
    }
}
