import Domain
@testable import Engine
import Foundation
@testable import Journal
import Testing

@Suite("Verification: recorded Check evidence")
struct FeatureVerificationCheckEvidenceTests {
    @Test("The verifier receives historical commands and commits, scoped to the Feature and repository")
    func instructionReceivesRecordedChecks() async throws {
        let world = try await VerificationWorld()
        try world.addClause(issue: "BACK-1", cid: "c1", text: "The tests pass.")
        let card = try #require(try world.journal.card(issueID: "BACK-1"))
        let earlierCard = try insertReconcilerCard(
            world.journal, cycleID: world.cycleID, issueID: "BACK-OLD", repository: "backend", state: .done
        )
        let otherRepoCard = try insertReconcilerCard(
            world.journal, cycleID: world.cycleID, issueID: "OTHER-REPO", repository: "unconfigured", state: .shelved
        )
        let otherFeature = try insertReconcilerFeature(world.journal, issueID: "OTHER-FEATURE")
        let otherCycle = try insertReconcilerCycle(world.journal, featureID: otherFeature)
        let unrelatedCard = try insertReconcilerCard(
            world.journal, cycleID: otherCycle, issueID: "UNRELATED", repository: "backend", state: .done
        )
        try appendCheck(world, cardID: earlierCard, command: "old-command test", commit: "old-head", status: 1)
        try appendCheck(world, cardID: unrelatedCard, command: "unrelated-command", commit: "unrelated", status: 0)
        try appendCheck(world, cardID: otherRepoCard, command: "other-repo-command", commit: "other", status: 0)
        try appendCheck(world, cardID: card.id, command: "new-command test", commit: "new-head", status: 0)
        try world.journal.append(.checkRan(
            cardID: card.id, issueID: card.issueID, attemptID: 1, result: .declaredNone,
            exitStatus: nil, output: nil, judgedCommit: "none-head"
        ))
        let dispatch = ScriptedVerifierDispatch([routeOther: .judgeAll()])

        _ = try await world.verification(resolver: verificationResolver(primary: routeOther), dispatch: dispatch)
            .verify(world.featureContext)

        let request = try #require(dispatch.requests.first)
        guard case .verification(let instruction) = request.instruction else {
            Issue.record("Expected a Verification instruction")
            return
        }
        let repository = try #require(instruction.repositories.first { $0.name == "backend" })
        #expect(repository.checkResults == [
            VerificationCheckResult(command: "old-command test", judgedCommit: "old-head", exitStatus: 1),
            VerificationCheckResult(command: "new-command test", judgedCommit: "new-head", exitStatus: 0)
        ])
        let rendered = instruction.render()
        #expect(rendered.contains("Command: old-command test\n    Judged commit: old-head\n    Exit status: 1"))
        #expect(!rendered.contains("unrelated-command"))
        #expect(!rendered.contains("other-repo-command"))
        #expect(!rendered.contains("none-head"))
        #expect(instruction.clauses.map(\.cid) == ["c1"])
    }

    @Test("The instruction names evidence limits, stale commits and uncovered commands on every Route")
    func instructionExplainsEvidenceLimits() {
        let instruction = VerificationInstruction(
            route: routeOther, featureTitle: "Feature", clauses: [],
            specificationSource: .specSource(SpecSource(path: "/spec")),
            repositories: [VerificationRepository(
                name: "backend", directory: "/backend", featureBranch: "feature",
                checkResults: [VerificationCheckResult(command: nil, judgedCommit: nil, exitStatus: 0)]
            ), VerificationRepository(name: "other", directory: "/other", featureBranch: "feature")]
        )
        let rendered = instruction.render()
        #expect(rendered.contains("judge clauses they cover, on any Route"))
        #expect(rendered.contains("name the stale record beside the clause"))
        #expect(rendered.contains("naming the command it would need"))
        #expect(rendered.contains("otherwise report `not checked`"))
        #expect(rendered.contains("Command: not recorded\n    Judged commit: not recorded\n    Exit status: 0"))
        #expect(rendered.contains("Recorded Check results: none"))
    }

    private func appendCheck(
        _ world: VerificationWorld, cardID: Int64, command: String, commit: String, status: Int32
    ) throws {
        let card = try world.journal.card(id: cardID)
        try world.journal.append(.checkRan(
            cardID: cardID, issueID: card.issueID, attemptID: 1,
            result: status == 0 ? .passed : .failed, exitStatus: status, output: nil,
            judgedCommit: commit, command: command
        ))
    }
}
