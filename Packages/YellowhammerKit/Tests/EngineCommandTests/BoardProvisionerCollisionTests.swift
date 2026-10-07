import Domain
import Engine
import Testing

// A collision on an item the Engine requires is an unfinished step (#361): setup lists it with the
// existing item to rename or delete, instead of reporting a board every Act then fails on.

private let team = BoardTeam(id: BoardObjectID(rawValue: "team-1"), key: "YLH", name: "Yellowhammer")

/// A board left over from the build before #334: the `Object Type` group with `Feature`, `Card` and
/// `Night Card`, all in team YLH.
private func boardFromPreviousBuild() async -> FakeProvisioningBoard {
    let scope = BoardProjectScope(id: BoardObjectID(rawValue: "proj-1"), name: "Yellowhammer", teams: [team])
    let board = FakeProvisioningBoard(project: scope)
    let objectType = await board.seed(label: "Object Type", team: team.id, isGroup: true)
    for child in ["Feature", "Card", "Night Card"] {
        await board.seed(label: child, team: team.id, parent: objectType)
    }
    return board
}

private func entry(
    _ report: ProvisioningReport, label name: String, in group: String
) -> ProvisioningEntry? {
    report.entries.first {
        if case .label(name, group, _) = $0.subject { return true }
        return false
    }
}

@Suite("BoardProvisioner: collisions are unfinished steps")
struct BoardProvisionerCollisionTests {
    @Test("A board from the previous build: Night Card collides with Object Type › Night Card, unfinished")
    func previousBuildNightCardIsUnfinished() async throws {
        let board = await boardFromPreviousBuild()

        let report = try await BoardProvisioner.provision(using: board, projectName: "Yellowhammer", createIn: nil)

        #expect(entry(report, label: "Feature Card", in: "Card Type")?.outcome == .created)
        #expect(entry(report, label: "Work Card", in: "Card Type")?.outcome == .created)
        let nightCard = try #require(entry(report, label: "Night Card", in: "Card Type"))
        #expect(nightCard.outcome == .collision("team"))
        #expect(nightCard.collidesWith == "label `Night Card` in group `Object Type`")
        #expect(report.hasUnfinishedSteps)
        #expect(report.unfinished.count == 1)
        #expect(report.unfinishedDescription.contains("Object Type"))
        #expect(report.createByHandGuideline == nil)
        let guideline = try #require(report.collisionGuideline)
        #expect(guideline.contains(
            "- rename or delete the label `Night Card` in group `Object Type` in team YLH; "
                + "it holds the name of label `Night Card` in group `Card Type`"
        ))

        let createsAfterFirstRun = await board.creates
        let second = try await BoardProvisioner.provision(using: board, projectName: "Yellowhammer", createIn: nil)
        #expect(await board.creates == createsAfterFirstRun)
        #expect(second.unfinished.count == 1)
    }

    @Test("A workspace label holding a child's name is named as a workspace label")
    func workspaceLabelCollisionNamesWorkspace() async throws {
        let scope = BoardProjectScope(id: BoardObjectID(rawValue: "proj-1"), name: "Yellowhammer", teams: [team])
        let board = FakeProvisioningBoard(project: scope)
        await board.seed(workspaceLabel: "Work Card")

        let report = try await BoardProvisioner.provision(using: board, projectName: "Yellowhammer", createIn: nil)

        let workCard = try #require(entry(report, label: "Work Card", in: "Card Type"))
        #expect(workCard.collidesWith == "workspace label `Work Card` (not in a group)")
        #expect(report.hasUnfinishedSteps)
    }

    @Test("A same-name workflow state of another category is named with its category")
    func workflowStateCollisionNamesCategory() async throws {
        let scope = BoardProjectScope(id: BoardObjectID(rawValue: "proj-1"), name: "Yellowhammer", teams: [team])
        let board = FakeProvisioningBoard(project: scope)
        await board.seed(state: "Blocked", team: team.id, category: .completed)

        let report = try await BoardProvisioner.provision(using: board, projectName: "Yellowhammer", createIn: nil)

        let blocked = try #require(report.entries.first {
            if case .workflowState("Blocked", _) = $0.subject { return true }
            return false
        })
        #expect(blocked.collidesWith == "workflow state `Blocked` of category completed")
        #expect(report.hasUnfinishedSteps)
        #expect(report.collisionGuideline?.contains("workflow state `Blocked` (category started)") == true)
    }
}
