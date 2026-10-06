import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
import Testing

// shift-scheduling/open-and-close-the-night-card (P5.7): NightCardScope.resolve, split out of
// NightCardTests.swift to keep that suite under the type body length limit.

@Suite("NightCardScope.resolve")
struct NightCardScopeTests {
    @Test("Throws when the Night Card label is missing")
    func resolveThrowsWhenNightCardLabelMissing() async throws {
        let boards = try await makeBoards(includeNightCard: false)
        let provisioning = boards.provisioning

        await #expect(throws: DispositionLabelsError.missing(
            group: BoardProvisioner.cardTypeGroup, label: CardType.nightCard.rawValue
        )) {
            try await NightCardScope.resolve(using: provisioning)
        }
    }

    @Test("Throws when no workflow state is completed")
    func resolveThrowsWhenNoCompletedState() async throws {
        let boardTeam = BoardTeam(id: teamID, key: "ENG", name: "Engineering")
        let scope = BoardProjectScope(id: BoardObjectID(rawValue: "proj-1"), name: "Yellowhammer", teams: [boardTeam])
        let provisioning = FakeProvisioningBoard(project: scope)
        try await seedDispositionLabels(on: provisioning, team: teamID)
        await provisioning.seed(state: "Todo", team: teamID, category: .unstarted)

        await #expect(throws: NightCardScopeError.noCompletedState(team: teamID)) {
            try await NightCardScope.resolve(using: provisioning)
        }
    }

    @Test("Succeeds with the seeded ids")
    func resolveSucceeds() async throws {
        let boards = try await makeBoards()
        let provisioning = boards.provisioning
        let ids = boards.ids

        let scope = try await NightCardScope.resolve(using: provisioning)

        #expect(scope.team == teamID)
        #expect(scope.nightCardLabel == ids["Night Card"])
    }
}
