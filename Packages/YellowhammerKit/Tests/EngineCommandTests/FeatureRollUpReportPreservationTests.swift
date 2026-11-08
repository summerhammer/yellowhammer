import Domain
@testable import Engine
import Foundation
@testable import Journal
import Testing

// #742: deterministic board composition, using recorded fixture verdicts rather than judging their quality.
@Suite("Feature Roll-up retains Verification and merge-test reports (#742)")
struct FeatureRollUpReportPreservationTests {
    private let issue = BoardObjectID(rawValue: "FEAT-1")
    private let prose = "Operator prose 🦜.\n"
    private let mergeReports = [
        "Mainline merge test for `backend`: untestable (as of Night 2026-09-24)",
        "Mainline merge test for `frontend`: [conflict: frontend] file.swift (as of Night 2026-09-24)"
    ]

    private func world() async throws -> VerificationWorld {
        let seed = prose + ManagedBlockFence.initialDescription(rendered: "old Roll-up")
        let world = try await VerificationWorld(featureDescription: seed)
        for cid in ["c1", "c2", "c3"] { try world.addClause(issue: "BACK-1", cid: cid) }
        try world.addAttempt(card: "BACK-1", route: routeWriter)
        let detail = String(repeating: "what was checked 🦜 ", count: 60)
        let clauses = ["c1", "c2", "c3"].map {
            VerifiedClause(cid: $0, issueID: "BACK-1", verdict: .met, whatWasChecked: detail, interpretation: detail)
        }
        let answer = DispatchResult.verifier(VerifierResult(outcome: .reported(clauses: clauses)))
        _ = try await world.verification(
            resolver: verificationResolver(primary: routeOther),
            dispatch: ScriptedVerifierDispatch([routeOther: .answer(answer)])
        ).verify(world.featureContext)
        let outbox = try #require(world.featureContext.act.outbox)
        for (index, report) in mergeReports.enumerated() {
            _ = try outbox.accept(OutboxWrite(
                key: "merge-report-\(index)",
                write: .updateManagedBlockLine(issue: issue, prefix: report, line: report)
            ))
        }
        _ = try await outbox.deliverPending()
        return world
    }

    private func block(_ world: VerificationWorld) throws -> String {
        FeatureRollUpBlock(rollUp: try FeatureRollUpMaintenance.rollUp(
            feature: world.featureContext.feature, cycleID: world.cycleID, journal: world.journal
        )).render()
    }

    private func report(_ world: VerificationWorld) throws -> VerificationReport {
        VerificationReport(
            record: try #require(try world.journal.featureVerification(cycleID: world.cycleID)),
            touchedRepositoryCount: try world.journal.touchedRepositories(featureID: world.featureID).count
        )
    }

    @Test("Act-end Roll-up retains the actual Verification and both lanes' reports, including on later changes")
    func actEndPreservesReports() async throws {
        let world = try await world()
        let outbox = try #require(world.featureContext.act.outbox)
        try await FeatureRollUpMaintenance.maintainRollUps(
            night: world.featureContext.act.night, journal: world.journal, outbox: outbox
        )
        let fullReport = try report(world).managedBlockLines()
        var description = try #require(await world.board.issue(issue)?.description)
        #expect(description.hasPrefix(prose))
        #expect(description.contains("### Cards"))
        #expect(description.contains(fullReport))
        for line in mergeReports { #expect(description.contains(line)) }
        #expect(!description.contains("old Roll-up"))

        let updates = await world.board.updateCalls
        let maintenance = FeatureRollUpMaintenance(journal: world.journal, outbox: outbox)
        _ = try await maintenance.maintain(feature: world.featureContext.feature, cycleID: world.cycleID)
        #expect(await world.board.updateCalls == updates)
        let card = try #require(try world.journal.card(issueID: "BACK-1"))
        try setCardState(world.journal, cardID: card.id, state: .blocked)
        _ = try await maintenance.maintain(feature: world.featureContext.feature, cycleID: world.cycleID)
        description = try #require(await world.board.issue(issue)?.description)
        #expect(description.contains("Blocked"))
        #expect(description.contains(fullReport))
        for line in mergeReports { #expect(description.components(separatedBy: line).count == 2) }
    }

    @Test("The report fits before maintenance but the combined Roll-up compacts it without dropping any clause")
    func combinedBudgetCompacts() async throws {
        let world = try await world()
        let original = try #require(await world.board.issue(issue)?.description)
        let budget = try DescriptionBudget(
            configured: original.utf16.count, limit: BoardDescriptionLimit(maximum: 100_000, unit: .utf16CodeUnits)
        )
        let outbox = Outbox(
            journal: world.journal, board: world.board, runID: world.featureContext.act.runID, act: .land,
            descriptionBudget: budget, clock: { landEpoch }
        )
        let rollUp = try block(world)
        let rungs = try report(world).managedBlockRenderings()
        let expected = prose + ManagedBlockFence.initialDescription(
            rendered: ([rollUp, rungs[1]] + mergeReports).joined(separator: "\n")
        )
        #expect(expected.utf16.count < budget.value)
        _ = try await FeatureRollUpMaintenance(journal: world.journal, outbox: outbox)
            .maintain(feature: world.featureContext.feature, cycleID: world.cycleID)

        let description = try #require(await world.board.issue(issue)?.description)
        #expect(description == expected)
        #expect(budget.fits(description))
        for cid in ["c1", "c2", "c3"] { #expect(description.contains("Verification: BACK-1 \(cid) · ")) }
        #expect(await world.board.comments.isEmpty)
        let updates = await world.board.updateCalls
        _ = try await FeatureRollUpMaintenance(journal: world.journal, outbox: outbox)
            .maintain(feature: world.featureContext.feature, cycleID: world.cycleID)
        #expect(await world.board.updateCalls == updates)
    }

    @Test("No combined rung fits: preserve the previous report and prose and emit one diagnostic")
    func combinedBudgetRefuses() async throws {
        let world = try await world()
        let original = try #require(await world.board.issue(issue)?.description)
        let shortest = ([try block(world), try report(world).managedBlockRenderings()[2]] + mergeReports)
            .joined(separator: "\n")
        let length = (prose + ManagedBlockFence.initialDescription(rendered: shortest)).utf16.count
        let budget = try DescriptionBudget(
            configured: length - 1, limit: BoardDescriptionLimit(maximum: 100_000, unit: .utf16CodeUnits)
        )
        let outbox = Outbox(
            journal: world.journal, board: world.board, runID: world.featureContext.act.runID, act: .land,
            descriptionBudget: budget, clock: { landEpoch }
        )
        let maintenance = FeatureRollUpMaintenance(journal: world.journal, outbox: outbox)
        _ = try await maintenance.maintain(feature: world.featureContext.feature, cycleID: world.cycleID)
        #expect(await world.board.issue(issue)?.description == original)
        #expect(try world.journal.events(ofType: .managedBlockOverBudget).count == 1)
        let comment = try #require(await world.board.comments.first?.body)
        #expect(comment.contains("Roll-up and reports"))
        #expect(comment.contains("\(length) UTF-16 code units"))
        #expect(!comment.contains("Route id"))
        _ = try await maintenance.maintain(feature: world.featureContext.feature, cycleID: world.cycleID)
        #expect(await world.board.comments.count == 1)
    }

    @Test("A persisted pending Roll-up keeps merge-test lines delivered after acceptance, without a Verification")
    func pendingRollUpPreservesFreshReports() async throws {
        let world = try await VerificationWorld(
            featureDescription: prose + ManagedBlockFence.initialDescription(rendered: "old")
        )
        let outbox = try #require(world.featureContext.act.outbox)
        let operation = BoardWrite.rewriteFeatureRollUp(issue: issue, renderings: ["new Roll-up"])
        let restored = try JSONDecoder().decode(BoardWrite.self, from: JSONEncoder().encode(operation))
        #expect(restored == operation)
        _ = try outbox.accept(OutboxWrite(key: "deferred-rollup", write: restored))
        await world.board.seed(
            issue: issue.rawValue,
            description: prose + ManagedBlockFence.initialDescription(
                rendered: (["old"] + mergeReports).joined(separator: "\n")
            )
        )
        _ = try await outbox.deliverPending()
        #expect(await world.board.issue(issue)?.description == prose + ManagedBlockFence.initialDescription(
            rendered: (["new Roll-up"] + mergeReports).joined(separator: "\n")
        ))
    }
}
