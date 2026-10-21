import Domain
@testable import Engine
import Foundation
@testable import Journal
import Testing

// Issue #542: a stop (Authoring Halt or Refusal) for a Feature name selected again after its Feature was
// authored and closed opens on a fresh Feature Issue, not the closed Feature's; inside one selection a halt
// and a later stop still share exactly one.

private let haltCause = AuthoringHaltCause.noBackwardCompatibleSeam(seam: "the shared endpoint")
private let refusalFinding = RefusalFinding(
    uncitable: [UncitableClause(
        level: "card", workCardTitle: "Backend one", text: "Ghost clause",
        citation: "epic/ghost", reason: "no such story"
    )],
    reselectionDepth: 2
)

@Suite("Authoring stops: a re-selected Feature name gets its own Feature Issue (#542)")
struct AuthoringStopReselectionTests {
    private let feature = FeatureName(rawValue: "FEAT-1")!

    /// Leaves the in-flight Feature the way an Abandoned settle would: its Cycle archived, the Feature abandoned.
    private func closeFeature(_ journal: JournalStore) throws {
        try journal.write { db in
            let stamp = JournalStore.timestamp(Date())
            try db.execute(sql: "UPDATE cycle SET archived_at = ? WHERE archived_at IS NULL", arguments: [stamp])
            try db.execute(sql: "UPDATE feature SET abandoned_at = ? WHERE abandoned_at IS NULL", arguments: [stamp])
        }
    }

    private func feature1IssueCount(_ rig: AuthoringRig) async -> Int {
        await rig.boards.writing.liveIssues.filter { $0.title == "FEAT-1" }.count
    }

    /// Halts (generation 0), authors the same name so the planner reuses the halt's issue, closes the
    /// Feature, and returns the first issue's id with the context to stop the re-selected Feature under.
    private func haltAuthorAndClose(_ rig: AuthoringRig) async throws -> (first: String, context: ActContext) {
        let halted = try rig.context()
        _ = try await AuthoringHalt.record(feature: feature, cause: haltCause, context: halted)
        let first = try #require(rig.journal.authoringHalts(feature: feature).first?.issueID)
        let authoring = try rig.context(previous: halted)
        let outcome = try await #require(rig.selection.transaction).author(
            try authoringSelection(), reselectionDepth: 0, context: authoring
        )
        #expect(outcome == .authored)
        let inFlight = try #require(try rig.journal.inFlightFeature())
        #expect(inFlight.feature.issueID == first)
        try closeFeature(rig.journal)
        return (first, try rig.context(previous: authoring))
    }

    @Test("A halt after the name's Feature was authored and closed opens a new Feature Issue")
    func haltOpensNewIssue() async throws {
        let rig = try await AuthoringRig()
        let (first, context) = try await haltAuthorAndClose(rig)
        let commentsOnFirst = await rig.boards.writing.comments.filter { $0.issue.rawValue == first }.count
        let updates = await rig.boards.writing.updateCalls

        _ = try await AuthoringHalt.record(feature: feature, cause: haltCause, context: context)

        #expect(await feature1IssueCount(rig) == 2)
        let halts = try rig.journal.authoringHalts(feature: feature)
        let newest = try #require(halts.last)
        let second = try #require(newest.issueID)
        #expect(second != first)
        let comments = await rig.boards.writing.comments
        #expect(comments.filter { $0.issue.rawValue == second }.count == 1)
        #expect(comments.filter { $0.issue.rawValue == first }.count == commentsOnFirst)
        #expect(await rig.boards.writing.updateCalls == updates)
    }

    @Test("A Refusal after the name's Feature was authored and closed opens a new Feature Issue")
    func refusalOpensNewIssue() async throws {
        let rig = try await AuthoringRig()
        let (first, context) = try await haltAuthorAndClose(rig)
        let commentsOnFirst = await rig.boards.writing.comments.filter { $0.issue.rawValue == first }.count
        let updates = await rig.boards.writing.updateCalls

        _ = try await RefusalRecording.record(feature: feature, finding: refusalFinding, context: context)

        #expect(await feature1IssueCount(rig) == 2)
        let refusal = try #require(try rig.journal.refusals(feature: feature).first)
        let second = try #require(refusal.issueID)
        #expect(second != first)
        let comments = await rig.boards.writing.comments
        #expect(comments.filter { $0.issue.rawValue == second }.count == 1)
        #expect(comments.filter { $0.issue.rawValue == first }.count == commentsOnFirst)
        #expect(await rig.boards.writing.updateCalls == updates)
    }

    @Test("The authoring after a new generation's halt reuses that halt's Feature Issue")
    func nextAuthoringReusesNewestIssue() async throws {
        let rig = try await AuthoringRig()
        let (first, context) = try await haltAuthorAndClose(rig)
        _ = try await AuthoringHalt.record(feature: feature, cause: haltCause, context: context)
        let second = try #require(rig.journal.authoringHalts(feature: feature).last?.issueID)
        #expect(second != first)
        #expect(try AuthoringStopBoard.knownIssueID(feature, rig.journal)?.rawValue == second)

        let outcome = try await #require(rig.selection.transaction).author(
            try authoringSelection(), reselectionDepth: 0, context: rig.context(previous: context)
        )

        #expect(outcome == .authored)
        #expect(await feature1IssueCount(rig) == 2)
        #expect(try rig.journal.inFlightFeature()?.feature.issueID == second)
        #expect(try tableRowCount(rig.journal, table: "feature") == 2)
    }

    @Test("A stop id no create of this generation made is not reused, so the authoring still finalises")
    func orphanedStopIssueIsNotReused() async throws {
        let rig = try await AuthoringRig()
        let first = try rig.context()
        // A halt row holding an issue id the current generation's create key never produced.
        try insertAuthoringHaltRow(
            rig.journal, featureName: "FEAT-1", issueID: "orphaned-issue", state: .cleared,
            openedNightID: first.night.id
        )

        #expect(try await rig.run(first) == .authored)

        let authored = try #require(try rig.journal.inFlightFeature()).feature.issueID
        #expect(authored != "orphaned-issue")
        #expect(await feature1IssueCount(rig) == 1)
    }

    @Test("A rolled-back authoring between a halt and a later stop does not split the Feature Issue")
    func rolledBackAuthoringKeepsOneIssue() async throws {
        let rig = try await AuthoringRig()
        let halted = try rig.context()
        _ = try await AuthoringHalt.record(feature: feature, cause: haltCause, context: halted)
        let plan = FeatureAuthoringAcceptedPayload(
            name: "FEAT-1", groupKey: "authoring:FEAT-1:0", featureKey: "feature:FEAT-1:0:create",
            nightID: halted.night.id, cards: [], adoptions: [], bases: []
        )
        // A rollback through the rig never gets accepted, so the accepted / failed pair is appended directly.
        _ = try rig.journal.append(
            .featureAuthoringAccepted(plan), act: .author, runID: halted.runID, nightID: halted.night.id
        )
        _ = try rig.journal.append(
            .featureAuthoringFailed(name: "FEAT-1", groupKey: plan.groupKey, reason: "rolled back"),
            act: .author, runID: halted.runID, nightID: halted.night.id
        )
        #expect(try rig.journal.authoringTransactionCount(feature: "FEAT-1") == 1)
        #expect(try rig.journal.authoredFeatureCount(feature: "FEAT-1") == 0)

        _ = try await AuthoringHalt.record(feature: feature, cause: haltCause, context: rig.context(previous: halted))

        #expect(await feature1IssueCount(rig) == 1)
        #expect(await rig.boards.writing.createIssueCalls == 1)
    }

    @Test("A first-generation stop creates its Feature Issue under the unscoped key")
    func firstGenerationKeyIsUnchanged() async throws {
        let rig = try await AuthoringRig()
        let context = try rig.context()
        _ = try await AuthoringHalt.record(feature: feature, cause: haltCause, context: context)

        let outbox = try #require(context.outbox)
        let entry = try rig.journal.outboxEntry(clientID: outbox.clientID(for: "feature:FEAT-1:halt:create"))
        #expect(entry?.operation == "issueCreate")
        #expect(try AuthoringStopBoard.createKey(feature, rig.journal) == "feature:FEAT-1:halt:create")
    }
}
