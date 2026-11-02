import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
@testable import Journal
import Testing

@Suite("Halted Feature Definition of Done repair (#678)")
struct HaltedFeatureDefinitionOfDoneRepairTests {
    @Test("A saved Feature Definition of Done is editable and survives Roll-up maintenance")
    func savedField() async throws {
        let world = try await DraftWorld()
        try await world.haltTheFeature()
        let issue = try world.issueID()
        let before = try #require(await world.writing.issue(issue)?.description)
        #expect(FeatureDefinitionOfDone.parse(before).clauses.count == 1)
        let edited = before.replacingOccurrences(of: "The Feature is done.", with: "Operator acceptance clause.")
        await world.writing.edit(issue, description: edited)
        let context = try world.context(night: "2026-10-02")
        try await FeatureRollUpMaintenance.maintainRollUps(
            night: context.night, journal: world.journal, outbox: context.outbox
        )
        let after = try #require(await world.writing.issue(issue)?.description)
        #expect(FeatureDefinitionOfDone.parse(after).clauses.first?.text == "Operator acceptance clause.")
    }

    @Test("A pre-breakdown Feature gets its saved field when the missing breakdown later halts")
    func savedFieldOnExistingFeature() async throws {
        let world = try await DraftWorld()
        let context = try world.context(night: "2026-10-01")
        _ = try await AuthoringHalt.record(
            feature: world.feature, cause: .noBackwardCompatibleSeam(seam: "seam"), context: context
        )
        let issue = try world.issueID()
        #expect(await world.writing.issue(issue)?.description?.contains("Definition of done") == false)
        _ = try await AuthoringHalt.record(
            feature: world.feature, cause: .noBackwardCompatibleSeam(seam: "seam"),
            selection: try authoringSelection(), breakdown: try overlappingBreakdown(), context: context
        )
        let saved = try #require(await world.writing.issue(issue)?.description)
        #expect(FeatureDefinitionOfDone.parse(saved).clauses.count == 1)
        let edited = saved.replacingOccurrences(of: "The Feature is done.", with: "Operator edit.")
        await world.writing.edit(issue, description: edited)
        try await HaltDrafts.ensureFeatureDefinitionOfDonePosted(halt: world.halt(), context: context)
        #expect(await world.writing.issue(issue)?.description == edited, "replay keeps the edit")
    }

    @Test("A valid Feature edit is accepted with the plan, while other Feature text is kept and not read",
          arguments: [true, false])
    func validEdit(outsideNotes: Bool) async throws {
        let world = try await DraftWorld()
        try await world.haltTheFeature()
        let issue = try world.issueID()
        let before = try #require(await world.writing.issue(issue)?.description)
        let edited = before.replacingOccurrences(of: "The Feature is done.", with: "Operator acceptance clause.")
            .replacingOccurrences(of: FeatureAuthoringProse.end,
                                  with: "\n\n### Operator heading\nOperator notes.\n"
                                    + "\n## Why this Feature\nOperator reasoning.\n"
                                    + FeatureAuthoringProse.end)
            + (outsideNotes ? "\n\nOperator notes outside the authored region." : "")
        await world.writing.edit(issue, description: edited)
        try await world.repairTheOverlap()
        try await world.runAuthorAct(night: "2026-10-02")
        #expect(try world.journal.inFlightFeature()?.feature.issueID == issue.rawValue)
        let after = try #require(await world.writing.issue(issue)?.description)
        #expect(FeatureDefinitionOfDone.parse(after).clauses.first?.text == "Operator acceptance clause.")
        #expect(after.contains("### Operator heading\nOperator notes."))
        #expect(after.contains("## Why this Feature\nOperator reasoning."))
        if outsideNotes { #expect(after.hasSuffix("Operator notes outside the authored region.")) }
        #expect(!after.contains(HaltDrafts.featureHeadline), "acceptance removes the engine's draft notice")
        #expect(await world.comments(on: issue).contains { $0.contains("not read as repair input") })
        let plans = try world.journal.events(ofType: .featureAuthoringAccepted).compactMap { record in
            if case .featureAuthoringAccepted(let plan) = record.event { return plan }
            return nil
        }
        #expect(plans.last?.featureClauses.first?.text == "Operator acceptance clause.")
    }

    @Test("Zero citable Feature clauses keeps the halt and each failing clause with its reason")
    func invalidEdit() async throws {
        let world = try await DraftWorld()
        let halt = try await world.haltTheFeature()
        let issue = try world.issueID()
        let before = try #require(await world.writing.issue(issue)?.description)
        let edited = try #require(FeatureDefinitionOfDone.replace(
            in: before, section: "## Definition of done\n\n- [ ] First failing clause.\n- [ ] Second failing clause."
        ))
        await world.writing.edit(issue, description: edited)
        try await world.repairTheOverlap()
        try await world.runAuthorAct(night: "2026-10-02")
        #expect(try world.halt().state == .open)
        #expect(await world.writing.issue(issue)?.description == edited)
        #expect(try tableRowCount(world.journal, table: "cycle") == 0)
        #expect(try tableRowCount(world.journal, table: "attempt") == 0)
        #expect(try tableRowCount(world.journal, table: "refusal") == 0)
        #expect(try world.journal.authoringFaultCount(feature: world.feature).count == Int.zero)
        #expect(world.rig.drafting.callCount == 1)
        let diagnostic = try #require(try world.journal.authoringHaltCheckpoint(haltID: halt.id)?.repairDiagnostic)
        #expect(diagnostic.contains("First failing clause.") && diagnostic.contains("Second failing clause."))
        #expect(diagnostic.contains("the clause has no citation"))
    }

    @Test("An uncitable Feature clause beside a citable one is dropped and named in the acceptance comment")
    func mixedClauses() async throws {
        let world = try await DraftWorld()
        try await world.haltTheFeature()
        let issue = try world.issueID()
        let before = try #require(await world.writing.issue(issue)?.description)
        let edited = before.replacingOccurrences(of: FeatureAuthoringProse.end,
                                               with: "- [ ] Uncitable extra.\n" + FeatureAuthoringProse.end)
        await world.writing.edit(issue, description: edited)
        try await world.repairTheOverlap()
        try await world.runAuthorAct(night: "2026-10-02")
        #expect(try world.journal.inFlightFeature() != nil)
        let after = try #require(await world.writing.issue(issue)?.description)
        #expect(!after.contains("Uncitable extra."))
        #expect(await world.comments(on: issue).contains {
            $0.contains("is accepted") && $0.contains("Uncitable extra.")
                && $0.contains("the clause has no citation")
        })
    }

    @Test("A missing or malformed saved Feature field stays invalid rather than using the checkpoint",
          arguments: ["## Removed field\nOperator text", "## Definition of done\nnot a checklist clause"])
    func unreadableField(prose: String) async throws {
        let world = try await DraftWorld()
        try await world.haltTheFeature()
        let issue = try world.issueID()
        let before = try #require(await world.writing.issue(issue)?.description)
        let edited = try #require(FeatureAuthoringProse.replace(in: before, prose: prose))
        await world.writing.edit(issue, description: edited)
        try await world.repairTheOverlap()
        try await world.runAuthorAct(night: "2026-10-02")
        #expect(try world.halt().state == .open)
        #expect(await world.writing.issue(issue)?.description == edited)
        #expect(try tableRowCount(world.journal, table: "cycle") == 0)
        #expect(world.rig.drafting.callCount == 1)
    }

    @Test("A Feature clause edited between validation and acceptance is a revision change")
    func changedBeforeAcceptance() async throws {
        let world = try await DraftWorld()
        let halt = try await world.haltTheFeature()
        try await world.repairTheOverlap()
        let context = try world.context(night: "2026-10-02")
        try await HaltedFeatureRepair.observe(context: context)
        let checkpoint = try #require(try world.journal.authoringHaltCheckpoint(haltID: halt.id))
        let snapshot = try #require(
            try await HaltRepairSnapshot.take(halt: halt, checkpoint: checkpoint, context: context)
        )
        let issue = try world.issueID()
        let plan = AuthoringPlan(
            writes: [], record: FeatureAuthoringAcceptedPayload(
                name: "FEAT-1", groupKey: "authoring:test", featureKey: "feature:test", nightID: context.night.id,
                cards: [], adoptions: [], bases: []
            ), reusedFeatureIssue: issue, repairSnapshot: snapshot
        )
        let before = try #require(await world.writing.issue(issue)?.description)
        await world.writing.edit(
            issue, description: before.replacingOccurrences(of: "The Feature is done.", with: "Changed.")
        )
        #expect(try await HaltedFeatureRepair.revalidateBeforeAcceptance(plan, context: context) == .authoringPending)
        #expect(try tableRowCount(world.journal, table: "cycle") == 0)
    }
}
