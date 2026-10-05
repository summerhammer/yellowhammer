import Config
import Domain
import Foundation
import Testing

@Suite("Add Project draft: the Linear workspace")
struct AddProjectDraftLinearStepTests {
    private let waysOut = "Choose a new Project id, or archive the old Journal (move it out of journals/) first."

    @Test("An empty registry asks to connect a workspace, before anything else")
    func emptyRegistry() {
        var draft = AddProjectDraft()
        #expect(draft.problems(in: .board) == ["Connect a Linear workspace."])
        draft.linearInstallationName = "acme"
        #expect(draft.problems(in: .board) == ["Connect a Linear workspace."])
    }

    @Test("No selection, or a name missing from the registry, asks to choose the workspace")
    func noSelection() {
        var draft = AddProjectDraft()
        draft.context.linearInstallations = [addProjectInstallation()]
        let expected = ["Choose the Linear workspace, or connect another."]
        #expect(draft.problems(in: .board) == expected)
        draft.linearInstallationName = "gone"
        #expect(draft.selectedLinearInstallation == nil)
        #expect(draft.problems(in: .board) == expected)
    }

    @Test("A selected entry without an Operator identity asks for one, before the Linear project")
    func noOperatorIdentity() {
        var draft = AddProjectDraft()
        draft.context.linearInstallations = [addProjectInstallation(operatorIdentity: nil)]
        draft.selectLinearInstallation("acme")
        #expect(draft.problems(in: .board) == ["Choose your Operator identity in \u{201c}acme\u{201d}."])
    }

    @Test("With a workspace and an Operator identity, the Linear project problems follow")
    func linearProjectProblemsFollow() {
        var draft = AddProjectDraft()
        draft.context.linearInstallations = [addProjectInstallation()]
        draft.selectLinearInstallation("acme")
        #expect(draft.problems(in: .board) == ["Choose the Linear project, or create one in a team."])
        draft.linearProjectID = "ACME"
        #expect(draft.problems(in: .board) == ["Verify the Linear project id."])
        draft.linearVerification = .verified(name: "Acme", teamNames: ["Engineering"])
        #expect(draft.problems(in: .board).isEmpty)
        #expect(draft.selectedLinearInstallation?.name == "acme")
    }

    @Test("Pasted Linear project id verification outcomes")
    func verificationOutcomes() {
        var draft = AddProjectDraft()
        draft.context.linearInstallations = [addProjectInstallation()]
        draft.selectLinearInstallation("acme")
        draft.linearProjectID = "ACME"
        #expect(draft.linearVerification == .unchecked)
        #expect(draft.problems(in: .board) == ["Verify the Linear project id."])

        draft.linearVerification = .checking
        #expect(draft.problems(in: .board) == ["Verify the Linear project id."])

        draft.linearVerification = .notFound
        #expect(draft.problems(in: .board) == ["No Linear project has that id in acme."])

        draft.linearVerification = .noTeamAccess(teamNames: ["Payments"])
        #expect(draft.problems(in: .board) == ["Yellowhammer is not a member of the team Payments."])

        draft.linearVerification = .noTeamAccess(teamNames: ["Engineering", "Payments"])
        #expect(draft.problems(in: .board) == ["Yellowhammer is not a member of the teams Engineering and Payments."])

        draft.linearVerification = .noTeamAccess(teamNames: [])
        #expect(draft.problems(in: .board) == ["Yellowhammer is not a member of the team."])

        draft.linearVerification = .verified(name: "Acme", teamNames: ["Engineering"])
        #expect(draft.problems(in: .board).isEmpty)
    }

    @Test("Picking a listed Linear project is verified automatically; editing un-verifies")
    func pickingListedAndEditing() {
        var draft = AddProjectDraft()
        draft.context.linearInstallations = [addProjectInstallation()]
        draft.selectLinearInstallation("acme")
        draft.context.linearProjects = [
            SetupChoices.LinearProject(id: "ACME", name: "Acme Mobile", teamNames: ["Engineering"])
        ]

        draft.linearProjectID = "ACME"
        #expect(draft.isLinearProjectVerified)
        #expect(draft.effectiveLinearVerification == .verified(name: "Acme Mobile", teamNames: ["Engineering"]))
        #expect(draft.problems(in: .board).isEmpty)

        // Editing un-verifies
        draft.linearProjectID = "OTHER"
        #expect(!draft.isLinearProjectVerified)
        #expect(draft.linearVerification == .unchecked)
        #expect(draft.problems(in: .board) == ["Verify the Linear project id."])
    }

    @Test("Selecting another workspace clears its teams, Linear projects and choices; re-selecting changes nothing")
    func selectClears() throws {
        var draft = completeAddProjectDraft()
        draft.context.linearInstallations.append(addProjectInstallation(name: "beta", workspace: "workspace-2"))
        draft.teamKey = "ENG"
        draft.context.teams = [SetupChoices.Team(id: "t1", key: "ENG", name: "Engineering")]
        draft.context.linearProjects = [SetupChoices.LinearProject(id: "ACME", name: "Acme Mobile", teamNames: [])]

        draft.selectLinearInstallation("acme")
        #expect(draft.teamKey == "ENG")
        #expect(draft.linearProjectID == "ACME")
        #expect(draft.context.teams.count == 1)
        #expect(draft.context.linearProjects.count == 1)

        draft.selectLinearInstallation("beta")
        #expect(draft.linearInstallationName == "beta")
        #expect(draft.teamKey == nil)
        #expect(draft.linearProjectID.isEmpty)
        #expect(draft.context.teams.isEmpty)
        #expect(draft.context.linearProjects.isEmpty)
    }

    @Test("The summary names the workspace, or says none is chosen")
    func summary() {
        var draft = AddProjectDraft()
        #expect(draft.summary(of: .board) == "No Linear workspace")
        draft = completeAddProjectDraft()
        draft.context.linearProjects = [SetupChoices.LinearProject(id: "ACME", name: "Acme Mobile", teamNames: [])]
        #expect(draft.summary(of: .board) == "\u{201c}Acme Mobile\u{201d} \u{b7} acme")
    }

    // MARK: Kept Journals

    private func reusing(_ kept: AddProjectContext.KeptJournal?, selecting: Bool = true) -> AddProjectDraft {
        var draft = completeAddProjectDraft()
        if !selecting { draft.linearInstallationName = nil }
        draft.context.journalProjectIDs = ["acme"]
        if let kept { draft.context.keptJournals["acme"] = kept }
        return draft
    }

    @Test("A kept Journal from another workspace is refused")
    func differentWorkspace() {
        let draft = reusing(.workspace(BoardObjectID(rawValue: "workspace-other")))
        #expect(draft.reusesJournal)
        #expect(draft.problems(in: .project) == [
            "The kept Journal for \u{201c}acme\u{201d} was built against another Linear workspace than "
                + "\u{201c}acme\u{201d}. " + waysOut
        ])
    }

    @Test("A kept Journal that cannot be read is refused")
    func unreadable() {
        let draft = reusing(.unreadable("schema too new"))
        #expect(draft.problems(in: .project) == [
            "The kept Journal for \u{201c}acme\u{201d} cannot be read (schema too new). " + waysOut
        ])
    }

    @Test("A kept Journal from the same workspace, or with no workspace chosen yet, is fine")
    func compatible() {
        #expect(reusing(.workspace(BoardObjectID(rawValue: "workspace-1"))).problems(in: .project).isEmpty)
        let unselected = reusing(.workspace(BoardObjectID(rawValue: "workspace-other")), selecting: false)
        #expect(unselected.problems(in: .project).isEmpty)
        #expect(reusing(nil).problems(in: .project).isEmpty)
    }

    @Test("An id with an existing Project file is not a reuse, whatever the Journal says")
    func existingProjectIsNotReuse() {
        var draft = reusing(.unreadable("broken"))
        draft.context.existingProjectIDs = ["acme"]
        #expect(!draft.reusesJournal)
        #expect(draft.problems(in: .project) == ["A Project \u{201c}acme\u{201d} already exists."])
    }
}
