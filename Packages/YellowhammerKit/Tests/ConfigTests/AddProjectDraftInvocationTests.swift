import Config
import Domain
import Foundation
import Testing

@Suite("Add Project draft: setup invocation")
struct AddProjectDraftInvocationTests {
    @Test("A complete draft maps to the project-and-jobs invocation")
    func complete() throws {
        let draft = completeAddProjectDraft()
        let expected = SetupInvocation(
            project: SetupInvocation.Project(
                id: "acme", name: "Acme", linearProject: .existing("ACME"), specSource: "/work/acme-spec",
                repos: [
                    SetupInvocation.Repo(
                        name: "acme-backend", role: "backend", path: "/work/acme-backend", check: "make test"
                    )
                ]
            ),
            jobs: .install
        )
        #expect(draft.setupInvocation == expected)
        #expect(try draft.setupInvocation.arguments() == [
            "setup", "--init", "--project", "acme", "--project-name", "Acme", "--linear-project", "ACME",
            "--spec-source", "/work/acme-spec", "--repo", "acme-backend,backend,/work/acme-backend,make test",
            "--install-jobs"
        ])
    }

    @Test("Creating the Linear project in a team passes the team key")
    func createInTeam() throws {
        var draft = completeAddProjectDraft()
        draft.linearChoice = .createInTeam
        draft.teamKey = "ENG"
        draft.jobs = .notNow
        let arguments = try draft.setupInvocation.arguments()
        #expect(arguments.contains("--linear-team"))
        #expect(arguments.contains("ENG"))
        #expect(!arguments.contains("--linear-project"))
        #expect(!arguments.contains("--install-jobs"))
        #expect(draft.setupInvocation.project?.linearProject == .createInTeam(key: "ENG"))
    }

    @Test("A Spec Source that is a Repo passes no --spec-source")
    func specRepo() throws {
        var draft = completeAddProjectDraft()
        draft.addSpecRepo(path: "/work/acme-spec")
        #expect(draft.setupInvocation.project?.specSource == nil)
        let arguments = try draft.setupInvocation.arguments()
        #expect(!arguments.contains("--spec-source"))
        #expect(arguments.contains("acme-spec,spec,/work/acme-spec,none"))
    }

    @Test("Exporting to cron passes the folder and --cron")
    func exportCron() throws {
        var draft = completeAddProjectDraft()
        draft.jobs = .export
        draft.exportDirectory = "/tmp/jobs"
        draft.exportUsesCron = true
        #expect(draft.setupInvocation.jobs == .export(directory: "/tmp/jobs", cron: true))
        let arguments = try draft.setupInvocation.arguments()
        #expect(Array(arguments.suffix(3)) == ["--export-jobs", "/tmp/jobs", "--cron"])
    }

    @Test("Ids, paths and Repo fields are trimmed; the name is as typed")
    func trimming() {
        var draft = AddProjectDraft()
        draft.projectID = " acme "
        draft.name = "Acme "
        draft.linearProjectID = " ACME "
        draft.specSourcePath = " /spec "
        draft.exportDirectory = " /out "
        draft.jobs = .export
        draft.repos = [AddProjectDraft.Repo(path: " /w/a ", name: " a ", role: " web ", check: " none ")]
        let project = draft.setupInvocation.project
        #expect(project?.id == "acme")
        #expect(project?.name == "Acme ")
        #expect(project?.linearProject == .existing("ACME"))
        #expect(project?.specSource == "/spec")
        #expect(project?.repos == [SetupInvocation.Repo(name: "a", role: "web", path: "/w/a", check: "none")])
        #expect(draft.setupInvocation.jobs == .export(directory: "/out", cron: false))
    }

    @Test("Nothing machine-wide is carried")
    func nothingMachineWide() {
        let invocation = completeAddProjectDraft().setupInvocation
        #expect(invocation.linearCredential == nil)
        #expect(invocation.githubCredential == nil)
        #expect(invocation.cliAdapters.isEmpty)
        #expect(invocation.route == nil)
        #expect(invocation.fallbacks.isEmpty)
        #expect(invocation.operatorID == nil)
    }

    @Test("Bounds are written only after a successful setup, and never at the defaults")
    func boundsToWrite() {
        var draft = completeAddProjectDraft()
        #expect(draft.boundsToWrite(afterExitStatus: 0) == nil)
        draft.bounds.attemptsPerCard = 5
        #expect(draft.boundsToWrite(afterExitStatus: 1) == nil)
        #expect(draft.boundsToWrite(afterExitStatus: 0) == draft.bounds)
    }
}
