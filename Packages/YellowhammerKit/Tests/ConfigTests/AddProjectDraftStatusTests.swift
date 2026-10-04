import Config
import Domain
import Foundation
import Testing

@Suite("Add Project draft: status and problems")
struct AddProjectDraftStatusTests {
    typealias Step = AddProjectDraft.Step

    @Test("A fresh draft has the Project current and the other steps upcoming")
    func freshDraft() {
        let draft = AddProjectDraft()
        #expect(draft.status(of: .project) == .current)
        for step in Step.allCases where step != .project {
            // Bounds and the Schedule have working defaults, but are not done until opened.
            #expect(draft.status(of: step) == .upcoming, "\(step)")
        }
    }

    @Test("Bounds and the Schedule are complete at their defaults once opened, and not before")
    func workingDefaultsNeedOpening() {
        var draft = AddProjectDraft()
        #expect(draft.problems(in: .bounds).isEmpty)
        #expect(!draft.isComplete(.bounds))
        #expect(!draft.isComplete(.jobs))
        draft.go(to: .bounds)
        #expect(draft.isComplete(.bounds))
        #expect(!draft.isComplete(.jobs))
        draft.go(to: .jobs)
        #expect(draft.isComplete(.jobs))
        #expect(draft.status(of: .bounds) == .done)
    }

    @Test("A step reveals its problems only once left, never on its first opening")
    func problemsRevealedOnceLeft() {
        var draft = AddProjectDraft()
        #expect(!draft.revealsProblems(in: .project))
        draft.go(to: .project)
        #expect(!draft.revealsProblems(in: .project))
        draft.go(to: .repos)
        #expect(draft.revealsProblems(in: .project))
        #expect(!draft.revealsProblems(in: .repos))
        draft.go(to: .project)
        #expect(draft.revealsProblems(in: .repos))
        #expect(draft.status(of: .project) == .problem)
    }

    @Test("A visited incomplete step is a problem, a complete one is done even when current")
    func visitedAndComplete() {
        var draft = AddProjectDraft()
        draft.go(to: .repos)
        #expect(draft.status(of: .project) == .problem)
        #expect(draft.status(of: .repos) == .current)
        #expect(draft.status(of: .specSource) == .upcoming)

        draft = completeAddProjectDraft()
        #expect(draft.status(of: .project) == .done)
        draft.go(to: .repos)
        draft.go(to: .project)
        #expect(draft.status(of: .project) == .done)
    }

    @Test("Project problems: empty, refused characters, existing id")
    func projectProblems() {
        var draft = AddProjectDraft()
        #expect(draft.problems(in: .project) == ["Enter a Project id."])
        draft.projectID = "  "
        #expect(draft.problems(in: .project) == ["Enter a Project id."])
        for bad in ["a b", "caf\u{e9}", "a/b", "a.b"] {
            draft.projectID = bad
            #expect(
                draft.problems(in: .project) == ["A Project id is letters, digits, underscores and hyphens."],
                "\(bad)"
            )
        }
        draft.projectID = "acme_1-x"
        #expect(draft.problems(in: .project).isEmpty)

        draft.context.existingProjectIDs = ["acme_1-x"]
        #expect(draft.problems(in: .project) == ["A Project \u{201c}acme_1-x\u{201d} already exists."])
    }

    @Test("An id found only among the project files is taken")
    func idOnlyInProjectFiles() throws {
        let machine = try testEditingMachine()
        let directory = try makeEditingDirectory(machine: machine, projects: [])
        defer { cleanupEditingDirectory(directory) }
        let configuration = try Configuration.load(directory: directory)
        var draft = AddProjectDraft()
        draft.context = AddProjectContext(
            configuration: configuration, projectFileIDs: ["refused"], journalProjectIDs: []
        )
        draft.projectID = "refused"
        #expect(draft.problems(in: .project) == ["A Project \u{201c}refused\u{201d} already exists."])
    }

    @Test("Linear project problems")
    func linearProblems() {
        var draft = AddProjectDraft()
        draft.context.linearInstallations = [addProjectInstallation()]
        draft.selectLinearInstallation("acme")
        #expect(draft.problems(in: .board) == ["Choose the Linear project, or create one in a team."])
        draft.linearProjectID = "   "
        #expect(!draft.isComplete(.board))
        draft.linearProjectID = "ACME"
        #expect(draft.isComplete(.board))
        draft.linearChoice = .createInTeam
        #expect(draft.problems(in: .board) == ["Choose a team to create the Linear project in."])
        draft.teamKey = "ENG"
        #expect(draft.isComplete(.board))
    }

    @Test("Repos problems: none, missing fields, conflicts")
    func repoProblems() {
        var draft = AddProjectDraft()
        #expect(draft.problems(in: .repos) == ["Add at least one working Repo."])

        draft.addRepo(path: "/work/thing")
        #expect(draft.problems(in: .repos) == ["/work/thing needs a role and Check."])
        draft.repos[0].name = " "
        #expect(draft.problems(in: .repos) == ["/work/thing needs a name, role, and Check."])
        #expect(draft.missingFields(of: draft.repos[0]) == ["name", "role", "Check"])
        draft.repos[0] = AddProjectDraft.Repo(path: "/work/thing", role: "web", check: "none")
        #expect(draft.problems(in: .repos).isEmpty)
    }

    @Test("A Repo owned by another Project conflicts, whether written with ~ or absolute")
    func ownedByAnotherProject() {
        let home = NSHomeDirectory()
        var draft = AddProjectDraft()
        draft.context.repoOwners = [AddProjectContext.normalizedPath("~/dev/acme-web"): "Acme"]
        draft.repos = [AddProjectDraft.Repo(path: "\(home)/dev/acme-web/", role: "web", check: "none")]
        #expect(draft.conflict(for: draft.repos[0]) == "already a Repo of Acme")
        #expect(draft.problems(in: .repos) == ["~/dev/acme-web is already a Repo of Acme."])

        draft.repos = [AddProjectDraft.Repo(path: "~/dev/acme-web", role: "web", check: "none")]
        #expect(draft.conflict(for: draft.repos[0]) == "already a Repo of Acme")
    }

    @Test("A Repo declared twice and a Repo equal to the Spec Source conflict")
    func twiceAndSpecSource() {
        var draft = AddProjectDraft()
        draft.repos = [
            AddProjectDraft.Repo(path: "/work/a", role: "web", check: "none"),
            AddProjectDraft.Repo(path: "/work/a/../a", role: "web", check: "none")
        ]
        #expect(draft.conflict(for: draft.repos[0]) == "declared twice")

        draft.repos = [AddProjectDraft.Repo(path: "/work/a", role: "web", check: "none")]
        draft.useSpecSource("/work/a")
        #expect(draft.conflict(for: draft.repos[0]) == "already the Spec Source")
        draft.specChoice = .repo
        #expect(draft.conflict(for: draft.repos[0]) == nil)
    }

    @Test("Spec Source problems for a path")
    func specPathProblems() {
        var draft = AddProjectDraft()
        #expect(draft.problems(in: .specSource) == ["Choose the Spec Source folder."])
        draft.useSpecSource("/work/spec")
        #expect(draft.problems(in: .specSource).isEmpty)
        draft.repos = [AddProjectDraft.Repo(path: "/work/x-spec", name: "x-spec", role: "spec", check: "none")]
        #expect(draft.problems(in: .specSource)
            == ["x-spec has role \u{201c}spec\u{201d} too; a Project has exactly one."])
    }

    @Test("Spec Source problems for a Repo: zero, one, two spec Repos")
    func specRepoProblems() {
        var draft = AddProjectDraft()
        draft.specChoice = .repo
        #expect(draft.problems(in: .specSource) == ["No Repo has role \u{201c}spec\u{201d}."])
        draft.repos = [AddProjectDraft.Repo(path: "/w/a", role: "spec", check: "none")]
        #expect(draft.problems(in: .specSource).isEmpty)
        draft.repos.append(AddProjectDraft.Repo(path: "/w/b", role: "spec", check: "none"))
        #expect(draft.problems(in: .specSource)
            == ["2 Repos have role \u{201c}spec\u{201d}; a Project has exactly one."])
    }

    @Test("A Bound of 0 is a problem")
    func boundsProblems() {
        var draft = AddProjectDraft()
        #expect(draft.problems(in: .bounds).isEmpty)
        draft.bounds.attemptsPerCard = 0
        #expect(draft.problems(in: .bounds) == ["Attempts per Card must be at least 1."])
    }

    @Test("A Night that starts and ends at the same time is a problem on the jobs step")
    func jobsProblemWhenNightStartEqualsEnd() throws {
        var draft = completeAddProjectDraft()
        draft.schedule.nightEnd = draft.schedule.nightStart
        #expect(draft.problems(in: .jobs) == ["The Night cannot start and end at the same time."])
        draft.schedule.nightEnd = try #require(TimeOfDay("07:00"))
        #expect(draft.problems(in: .jobs).isEmpty)
    }

    @Test("Exporting the scheduled jobs needs a folder")
    func jobsProblems() {
        var draft = AddProjectDraft()
        draft.jobs = .export
        #expect(draft.problems(in: .jobs) == ["Choose the folder to export the scheduled jobs to."])
        draft.exportDirectory = "/tmp/jobs"
        #expect(draft.problems(in: .jobs).isEmpty)
        draft.jobs = .notNow
        draft.exportDirectory = ""
        #expect(draft.problems(in: .jobs).isEmpty)
    }

    @Test("A Journal left by a removed Project is reused, an existing Project's is not")
    func reusesJournal() {
        var draft = AddProjectDraft()
        draft.projectID = "old"
        #expect(!draft.reusesJournal)
        draft.context.journalProjectIDs = ["old"]
        #expect(draft.reusesJournal)
        draft.context.existingProjectIDs = ["old"]
        #expect(!draft.reusesJournal)
    }
}
