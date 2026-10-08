import Config
import Foundation
import Testing

@Suite("Add Project draft: navigation and editing")
struct AddProjectDraftNavigationTests {
    @Test("go(to:) jumps ahead and back, marking the step left and the target visited")
    func goTo() {
        var draft = AddProjectDraft()
        draft.go(to: .specSource)
        #expect(draft.step == .specSource)
        #expect(draft.visited == [.project, .specSource])
        draft.go(to: .board)
        #expect(draft.step == .board)
        #expect(draft.visited == [.project, .specSource, .board])
        #expect(draft.status(of: .specSource) == .problem)
        draft.go(to: .project)
        #expect(draft.step == .project)
    }

    @Test("Leaving a step marks it visited, so an incomplete one turns into a problem")
    func leavingMarksVisited() {
        var draft = AddProjectDraft()
        draft.go(to: .repos)
        draft.go(to: .bounds)
        #expect(draft.visited.contains(.repos))
        #expect(draft.status(of: .repos) == .problem)
        #expect(draft.status(of: .board) == .upcoming)
    }

    @Test("stillNeeded lists short titles and readyCount counts complete steps")
    func stillNeededAndReady() {
        var draft = AddProjectDraft()
        #expect(draft.readyCount == 0)
        #expect(draft.stillNeeded == "Still needed: Project, Board, Repos, GitHub, Spec Source, Bounds, and Schedule")
        draft = completeAddProjectDraft()
        #expect(draft.readyCount == 7)
        #expect(draft.stillNeeded == nil)
        #expect(draft.isComplete)
        draft.linearProjectID = ""
        draft.specSourcePath = ""
        #expect(draft.stillNeeded == "Still needed: Board and Spec Source")
        #expect(draft.incompleteSteps == [.board, .specSource])
    }

    @Test("The id follows the name until the id is edited")
    func nameAndID() {
        var draft = AddProjectDraft()
        draft.setName("Acme Mobile!")
        #expect(draft.projectID == "acme-mobile")
        draft.setProjectID("mine")
        draft.idConfirmed = true
        draft.setName("Other")
        #expect(draft.projectID == "mine")
        #expect(draft.idEdited)
        draft.setProjectID("mine2")
        #expect(!draft.idConfirmed)
        draft.setProjectID("")
        #expect(!draft.idEdited)
        draft.setName("Back")
        #expect(draft.projectID == "back")
    }

    @Test("A slug is ASCII lowercase letters, digits and single hyphens")
    func slug() {
        #expect(AddProjectDraft.slug("Acme Mobile!") == "acme-mobile")
        #expect(AddProjectDraft.slug("  --A__b  ") == "a-b")
        #expect(AddProjectDraft.slug("Caf\u{e9} \u{dc}") == "caf")
        #expect(AddProjectDraft.slug("\u{65e5}\u{672c}") == "")
        #expect(AddProjectDraft.slug("v2 Beta") == "v2-beta")
    }

    @Test("Roles are guessed from the folder name; spec never comes back as a working role")
    func roles() {
        #expect(AddProjectDraft.guessedRole(for: "/w/acme-backend") == "backend")
        #expect(AddProjectDraft.guessedRole(for: "/w/acme-spec") == "spec")
        #expect(AddProjectDraft.guessedRole(for: "/w/acme") == "")
        #expect(AddProjectDraft.workingRole(for: "/w/acme-spec") == "")
        #expect(AddProjectDraft.workingRole(for: "/w/acme-web") == "web")
        #expect(AddProjectDraft.suggestedChecks.last == "none")
    }

    @Test("addRepo guesses a role and removeRepo drops the Repo")
    func addAndRemove() {
        var draft = AddProjectDraft()
        draft.addRepo(path: "/w/acme-mobile")
        draft.addRepo(path: "/w/other")
        #expect(draft.repos.map(\.name) == ["acme-mobile", "other"])
        #expect(draft.repos.map(\.role) == ["mobile", ""])
        #expect(draft.repos.map(\.check) == ["", ""])
        draft.removeRepo(draft.repos[0].id)
        #expect(draft.repos.map(\.name) == ["other"])
    }

    @Test("useSpecSource clears every spec role back to a working role")
    func useSpecSource() {
        var draft = AddProjectDraft()
        draft.addRepo(path: "/w/acme-spec")
        draft.addRepo(path: "/w/acme-web")
        draft.useSpecRepo(draft.repos[0].id)
        #expect(draft.repos[0].role == "spec")
        draft.useSpecSource("/shared/spec")
        #expect(draft.specChoice == .path)
        #expect(draft.specSourcePath == "/shared/spec")
        #expect(draft.repos.map(\.role) == ["", "web"])
    }

    @Test("useSpecRepo gives one Repo the spec role and a declared Check, and demotes the other")
    func useSpecRepo() {
        var draft = AddProjectDraft()
        draft.addRepo(path: "/w/acme-spec")
        draft.addRepo(path: "/w/acme-web")
        draft.useSpecSource("/shared/spec")
        draft.useSpecRepo(draft.repos[1].id)
        #expect(draft.specChoice == .repo)
        #expect(draft.specSourcePath == "")
        #expect(draft.repos.map(\.role) == ["", "spec"])
        #expect(draft.repos[1].check == "none")
        draft.repos[0].check = "make test"
        draft.useSpecRepo(draft.repos[0].id)
        #expect(draft.repos.map(\.role) == ["spec", "web"])
        #expect(draft.repos[0].check == "make test")
    }

    @Test("addSpecRepo appends the checkout once, then reuses it")
    func addSpecRepo() {
        var draft = AddProjectDraft()
        draft.addSpecRepo(path: "/w/acme-spec")
        #expect(draft.repos.count == 1)
        #expect(draft.repos[0].role == "spec")
        #expect(draft.repos[0].check == "none")
        #expect(draft.specChoice == .repo)
        draft.addSpecRepo(path: "/w/acme-spec/")
        #expect(draft.repos.count == 1)

        var other = AddProjectDraft()
        other.addRepo(path: "/w/acme-spec")
        other.addSpecRepo(path: "/w/acme-spec")
        #expect(other.repos.count == 1)
        #expect(other.repos[0].role == "spec")
    }
}
