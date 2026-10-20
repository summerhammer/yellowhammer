import Domain
import Foundation
import Testing

@testable import Engine
@testable import EngineCommand

// board-projection/maintain-the-managed-block: Block Reason is Card content, not a label (Board
// Simplification Ruling 2026-10-20, roadmap P22.1).

private func blockedBlock(_ reason: BlockReason, state: CardState = .blocked) -> CardManagedBlock {
    CardManagedBlock(
        kind: "card", repository: "backend", scope: ["Sources/App/"], state: state, blockReason: reason.rawValue,
        lanePosition: 1, laneLength: 2, brief: ArchitecturalBrief(prose: "Wire the endpoint.", transcriptions: []),
        definitionOfDone: [
            DoDClause(cid: "c1", text: "It works", citation: "epic/story", citationProvenance: "machine-found")
        ],
        attempts: []
    )
}

@Suite("Block Reason as Card content")
struct BlockReasonAsContentTests {
    @Test("A board with no Block Reason group resolves its scope and provisions and verifies clean")
    func boardWithoutBlockReasonGroupIsComplete() async throws {
        let boards = try await makeBoards()
        let scope = try await BoardStateScope.resolve(using: boards.provisioning)
        #expect(scope.labels.blockReason.isEmpty)
        #expect(scope.labels.cardType.count == CardType.allCases.count)

        let provisioned = try await BoardProvisioner.provision(
            using: boards.provisioning, projectName: "Yellowhammer", createIn: nil
        )
        #expect(provisioned.changes.isEmpty)
        let verified = try await BoardProvisioner.verify(using: boards.provisioning, projectName: "Yellowhammer")
        #expect(verified.unfinishedItems.isEmpty)
        #expect(!verified.entries.contains { entry in
            if case .labelGroup("Block Reason", _) = entry.subject { return true }
            return false
        })
    }

    @Test("A legacy Block Reason group has its labels removed on a state change and never gets one added")
    func legacyBlockReasonLabelsAreRemovedNeverAdded() async throws {
        let boardTeam = BoardTeam(id: teamID, key: "ENG", name: "Engineering")
        let project = BoardProjectScope(id: BoardObjectID(rawValue: "proj-1"), name: "Yellowhammer", teams: [boardTeam])
        let board = FakeProvisioningBoard(project: project)
        try await seedDispositionLabels(on: board, team: teamID, legacyBlockReason: true)
        let labels = try DispositionLabels(labels: try await board.labels(team: teamID))
        #expect(labels.blockReason.count == BlockReason.allCases.count)

        for reason in BlockReason.allCases {
            let change = labels.change(for: .blocked, blockReason: reason)
            #expect(Set(change.addLabels) == [labels.cardType[.workCard]!])
            #expect(Set(change.removeLabels).isSuperset(of: Set(labels.blockReason.values)))
        }
    }

    @Test("A Blocked Work Card's managed block leads with its Block Reason and next action")
    func blockedBlockLeadsWithReasonAndNextAction() {
        for reason in BlockReason.allCases {
            let rendered = blockedBlock(reason).render()
            let first = rendered.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init)
            #expect(first == "**Blocked — \(reason.rawValue).** Next: \(reason.nextAction)")
            #expect(rendered.contains("**State:** Blocked\n") || rendered.contains("**State:** blocked\n"))
            #expect(!rendered.contains("— \(reason.rawValue)\n**Repo"))
        }
    }

    @Test("Check failure and reviewer rejection read differently")
    func checkFailureAndReviewerRejectionAreDistinct() {
        let check = blockedBlock(.checkFailure).render()
        let review = blockedBlock(.reviewerRejection).render()
        #expect(check.hasPrefix("**Blocked — check failure.**"))
        #expect(review.hasPrefix("**Blocked — reviewer rejection.**"))
        #expect(BlockReason.checkFailure.nextAction != BlockReason.reviewerRejection.nextAction)
    }

    @Test("A Card that is not Blocked keeps the old State line and gets no headline")
    func unblockedCardHasNoHeadline() {
        let rendered = blockedBlock(.checkFailure, state: .inProgress).render()
        #expect(rendered.hasPrefix("**Kind:**"))
        #expect(rendered.contains("— check failure"))
    }

    @Test("The parser reads blocks rendered by the new and the old format alike")
    func parserReadsOldAndNewFormat() {
        let new = blockedBlock(.checkFailure).render()
        let old = new
            .split(separator: "\n", omittingEmptySubsequences: false).dropFirst()
            .map { $0.hasPrefix("**State:**") ? "**State:** blocked — check failure" : String($0) }
            .joined(separator: "\n")
        for rendered in [new, old] {
            let parsed = CardManagedBlockParser.parse(block: rendered)
            #expect(parsed.briefProse == "Wire the endpoint.")
            #expect(parsed.scope == ["Sources/App/"])
            #expect(parsed.clauses.count == 1)
            #expect(DeltaRead.repository(inBlock: rendered) == "backend")
        }
    }

    @Test("A Feature Issue's roll-up names each Blocked member's reason and next action")
    func rollUpLineCarriesNextAction() {
        let member = RollUpMember(
            issueID: "ENG-1", title: "Wire it", repository: "backend", authoredOrder: 1, state: .blocked,
            blockReason: BlockReason.checkFailure.rawValue
        )
        let rollUp = FeatureRollUp(
            members: [member], lanesPushed: false, verificationPassed: false,
            mergedFraction: MergedFraction(mergedCount: 0, totalCount: 1), issueStanding: .authoring
        )
        let rendered = FeatureRollUpBlock(rollUp: rollUp).render()
        #expect(rendered.contains("(check failure) · next: \(BlockReason.checkFailure.nextAction)"))
    }
}
