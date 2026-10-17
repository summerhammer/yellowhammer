import Domain
@testable import Engine
import Foundation
import GRDB
@testable import Journal
import Testing

// Issue #538: an abandoned Feature selected again under the same name must author a new Feature, not
// resolve to the earlier transaction's applied creates (same Outbox keys) and leave its plan open forever.

@Suite("Authoring transaction: re-selecting a closed Feature's name (#538)")
struct AuthoringTransactionReselectionTests {
    private func twoBreakdowns() throws -> ScriptedBreakdown {
        ScriptedBreakdown(
            try authoringBreakdown(), try authoringBreakdown(backendTitles: ["Backend uno", "Backend dos"])
        )
    }

    /// Leaves the in-flight Feature the way an Abandoned settle would: its Cycle archived, the Feature abandoned.
    private func closeFeature(_ journal: JournalStore) throws {
        try journal.write { db in
            let stamp = JournalStore.timestamp(Date())
            try db.execute(sql: "UPDATE cycle SET archived_at = ? WHERE archived_at IS NULL", arguments: [stamp])
            try db.execute(sql: "UPDATE feature SET abandoned_at = ? WHERE abandoned_at IS NULL", arguments: [stamp])
        }
    }

    private func blockACard(_ journal: JournalStore) throws -> String {
        let card = try #require(try journal.cards().first)
        try journal.write { db in
            try db.execute(
                sql: "UPDATE card SET state = ? WHERE id = ?", arguments: [CardState.blocked.rawValue, card.id]
            )
        }
        return card.issueID
    }

    private func acceptedGroupKeys(_ journal: JournalStore) throws -> [String] {
        try journal.events(ofType: .featureAuthoringAccepted).compactMap { record -> String? in
            if case .featureAuthoringAccepted(let plan) = record.event { plan.groupKey } else { nil }
        }
    }

    @Test("Selecting an abandoned Feature's name again authors a new Feature under fresh keys")
    func reselectionAuthorsNewFeature() async throws {
        let rig = try await AuthoringRig(drafting: twoBreakdowns())
        let first = try rig.context()
        #expect(try await rig.run(first) == .authored)
        let firstFeature = try #require(try rig.journal.inFlightFeature()).feature.issueID
        let cardIssueID = try blockACard(rig.journal)
        try closeFeature(rig.journal)

        let outcome = try await #require(rig.selection.transaction).author(
            try authoringSelection(adopting: [cardIssueID]), reselectionDepth: 0,
            context: rig.context(previous: first)
        )

        #expect(outcome == .authored)
        #expect(try tableRowCount(rig.journal, table: "feature") == 2)
        #expect(try tableRowCount(rig.journal, table: "cycle") == 2)
        #expect(try rig.journal.events(ofType: .featureAuthored).count == 2)
        #expect(try acceptedGroupKeys(rig.journal) == ["authoring:FEAT-1:0", "authoring:FEAT-1:1"])
        let (newFeature, newCycleID) = try #require(try rig.journal.inFlightFeature())
        #expect(newFeature.issueID != firstFeature)
        let adopted = try #require(try rig.journal.cards().first { $0.issueID == cardIssueID })
        #expect(adopted.cycleID == newCycleID)
        let live = await rig.boards.writing.liveIssues
        #expect(live.filter { $0.title == "FEAT-1" }.count == 2)
        let adoptedIssue = try #require(live.first { $0.id.rawValue == cardIssueID })
        #expect(adoptedIssue.parent?.rawValue == newFeature.issueID)
        #expect(try rig.journal.unfinishedAuthoringPlan() == nil)
    }

    @Test("A plan an older build left open by a no-op finalise closes as a failed transaction")
    func stuckPlanClosesAsFailed() async throws {
        let rig = try await AuthoringRig()
        let first = try rig.context()
        #expect(try await rig.run(first) == .authored)
        let accepted = try rig.journal.events(ofType: .featureAuthoringAccepted)
        guard case .featureAuthoringAccepted(let plan) = try #require(accepted.first).event else {
            Issue.record("expected a featureAuthoringAccepted event")
            return
        }
        let stuck = try rig.context(previous: first)
        // The live stuck shape: a second acceptance with the first transaction's own keys.
        _ = try rig.journal.append(
            .featureAuthoringAccepted(plan), act: stuck.act, runID: stuck.runID, nightID: stuck.night.id
        )
        try closeFeature(rig.journal)
        #expect(try rig.journal.unfinishedAuthoringPlan() != nil)
        let selections = rig.selector.callCount

        let resumed = try await rig.run(stuck)

        #expect(resumed == .authoringRolledBack)
        let failed = try rig.journal.events(ofType: .featureAuthoringFailed).filter {
            if case .featureAuthoringFailed(_, let groupKey, _) = $0.event { return groupKey == plan.groupKey }
            return false
        }
        #expect(failed.count == 1)
        #expect(try rig.journal.unfinishedAuthoringPlan() == nil)
        #expect(try tableRowCount(rig.journal, table: "feature") == 1)
        #expect(rig.selector.callCount == selections)

        // The Project is no longer stuck: the next Act reaches selection.
        _ = try await rig.run(rig.context(previous: stuck))
        #expect(rig.selector.callCount == selections + 1)
    }

    @Test("A Feature name once halted and then authored does not reuse the halt's Feature Issue")
    func haltedNameReselectedCreatesNewIssue() async throws {
        let rig = try await AuthoringRig()
        let first = try rig.context()
        #expect(try await rig.run(first) == .authored)
        let firstFeature = try #require(try rig.journal.inFlightFeature()).feature.issueID
        try insertAuthoringHaltRow(
            rig.journal, featureName: "FEAT-1", issueID: firstFeature, state: .cleared, openedNightID: first.night.id
        )
        try closeFeature(rig.journal)

        let outcome = try await #require(rig.selection.transaction).author(
            try authoringSelection(), reselectionDepth: 0, context: rig.context(previous: first)
        )

        #expect(outcome == .authored)
        #expect(try tableRowCount(rig.journal, table: "feature") == 2)
        let newFeature = try #require(try rig.journal.inFlightFeature()).feature.issueID
        #expect(newFeature != firstFeature)
        #expect(await rig.boards.writing.liveIssues.filter { $0.title == "FEAT-1" }.count == 2)
    }
}
