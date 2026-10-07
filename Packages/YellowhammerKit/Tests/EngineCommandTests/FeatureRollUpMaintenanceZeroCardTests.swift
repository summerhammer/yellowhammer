import Domain
@testable import Engine
import Foundation
import GRDB
@testable import Journal
import Testing

// The Feature Roll-up's zero-Card standing, Shelved-Card write absence, and `maintainAll` (roadmap
// P12.3; spec: board-projection/maintain-the-managed-block, second story). Split out of
// FeatureRollUpMaintenanceTests.swift for the type/file length limits; fixtures live in
// FeatureRollUpMaintenanceFixtures.swift. `OutboxJournalFixture` is created inside every @Test.

@Suite("Feature Roll-up maintenance: zero-Card standings and maintainAll (P12.3)")
struct FeatureRollUpMaintenanceZeroCardTests {
    @Test("Zero-Card Refusal: open, expired, and answered render their standing and repost as it changes")
    func zeroCardRefusalStandings() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let world = try makeRollUpWorld(journal)
        await world.board.seed(issue: "REFUSAL-1", description: ManagedBlockFence.initialDescription(rendered: ""))
        try insertRefusalRow(
            journal, featureName: "refused-feature", issueID: "REFUSAL-1", state: .open,
            openedNightID: world.night.id
        )
        let maintenance = FeatureRollUpMaintenance(journal: journal, outbox: world.outbox)

        try await maintenance.maintainAll(night: world.night)
        var description = try #require(await world.board.issue(BoardObjectID(rawValue: "REFUSAL-1"))?.description)
        #expect(description.contains("waiting · no Cards yet · refusal awaiting you"))

        try updateRefusalState(journal, issueID: "REFUSAL-1", state: .expired)
        try await maintenance.maintainAll(night: world.night)
        description = try #require(await world.board.issue(BoardObjectID(rawValue: "REFUSAL-1"))?.description)
        #expect(description.contains("blocked · no Cards yet · reply overdue"))

        try updateRefusalState(journal, issueID: "REFUSAL-1", state: .answered)
        try await maintenance.maintainAll(night: world.night)
        description = try #require(await world.board.issue(BoardObjectID(rawValue: "REFUSAL-1"))?.description)
        #expect(description.contains("authoring · no Cards yet · in authoring"))
    }

    @Test("Zero-Card Authoring Halt: open, expired, and cleared render halt wording, never 'refusal'")
    func zeroCardAuthoringHaltStandings() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let world = try makeRollUpWorld(journal)
        await world.board.seed(issue: "HALT-1", description: ManagedBlockFence.initialDescription(rendered: ""))
        try insertAuthoringHaltRow(
            journal, featureName: "halted-feature", issueID: "HALT-1", state: .open, openedNightID: world.night.id
        )
        let maintenance = FeatureRollUpMaintenance(journal: journal, outbox: world.outbox)

        try await maintenance.maintainAll(night: world.night)
        var description = try #require(await world.board.issue(BoardObjectID(rawValue: "HALT-1"))?.description)
        #expect(description.contains("waiting · no Cards yet · halt awaiting you"))
        #expect(!description.contains("refusal"))

        try updateAuthoringHaltState(journal, issueID: "HALT-1", state: .expired)
        try await maintenance.maintainAll(night: world.night)
        description = try #require(await world.board.issue(BoardObjectID(rawValue: "HALT-1"))?.description)
        #expect(description.contains("blocked · no Cards yet · halt overdue"))
        #expect(!description.contains("refusal"))

        try updateAuthoringHaltState(journal, issueID: "HALT-1", state: .cleared)
        try await maintenance.maintainAll(night: world.night)
        description = try #require(await world.board.issue(BoardObjectID(rawValue: "HALT-1"))?.description)
        #expect(description.contains("authoring · no Cards yet · in authoring"))
        #expect(!description.contains("refusal"))
    }

    @Test("A Shelved Card receives no write of its own: no Outbox entry ever targets its issue")
    func shelvedCardReceivesNoWrite() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let world = try makeRollUpWorld(journal)
        await world.board.seed(issue: "FEAT-1", description: ManagedBlockFence.initialDescription(rendered: ""))
        let featureID = try insertGateFeature(
            journal, issueID: "FEAT-1", branch: "yh-proj-feat", repositories: ["backend"]
        )
        let cycleID = try gateCycleID(journal, featureID: featureID)
        try insertRollUpCard(
            journal, cycleID: cycleID, .init(issueID: "BACK-1", repository: "backend", order: 1, state: .done)
        )
        try insertRollUpCard(
            journal, cycleID: cycleID, .init(issueID: "BACK-2", repository: "backend", order: 2, state: .shelved)
        )
        let feature = try #require(try journal.feature(issueID: "FEAT-1"))
        let maintenance = FeatureRollUpMaintenance(journal: journal, outbox: world.outbox)

        _ = try await maintenance.maintain(feature: feature, cycleID: cycleID)

        let entries = try journal.read { db in
            try Int.fetchAll(db, sql: "SELECT id FROM outbox WHERE issue_id = ?", arguments: ["BACK-2"])
        }
        #expect(entries.isEmpty)
    }

    @Test("maintainAll covers the in-flight Feature and a zero-Card refused issue in one call")
    func maintainAllCoversBothCandidates() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let world = try makeRollUpWorld(journal)
        await world.board.seed(issue: "FEAT-1", description: ManagedBlockFence.initialDescription(rendered: ""))
        await world.board.seed(issue: "REFUSAL-1", description: ManagedBlockFence.initialDescription(rendered: ""))
        let featureID = try insertGateFeature(
            journal, issueID: "FEAT-1", branch: "yh-proj-feat", repositories: ["backend"], inFlight: true
        )
        let cycleID = try gateCycleID(journal, featureID: featureID)
        try insertRollUpCard(
            journal, cycleID: cycleID, .init(issueID: "BACK-1", repository: "backend", order: 1, state: .done)
        )
        try insertRefusalRow(
            journal, featureName: "refused-feature", issueID: "REFUSAL-1", state: .open,
            openedNightID: world.night.id
        )
        let maintenance = FeatureRollUpMaintenance(journal: journal, outbox: world.outbox)

        try await maintenance.maintainAll(night: world.night)

        #expect(try journal.managedBlockLastPostedHash(issueID: "FEAT-1") != nil)
        #expect(try journal.managedBlockLastPostedHash(issueID: "REFUSAL-1") != nil)
        let featureDescription = try #require(await world.board.issue(BoardObjectID(rawValue: "FEAT-1"))?.description)
        #expect(featureDescription.contains("running · 1 of 1 Cards landed · all on track"))
        let refusalDescription = try #require(
            await world.board.issue(BoardObjectID(rawValue: "REFUSAL-1"))?.description
        )
        #expect(refusalDescription.contains("waiting · no Cards yet · refusal awaiting you"))
    }
}
