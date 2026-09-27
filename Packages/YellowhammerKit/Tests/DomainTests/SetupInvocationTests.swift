import Domain
import Testing

struct SetupInvocationTests {
    @Test("A full invocation builds every option, in order")
    func fullInvocationBuildsEveryOption() throws {
        let invocation = SetupInvocation(
            linearCredential: "keychain:linear",
            githubCredential: "keychain:github",
            cliAdapters: ["claude", "codex=codex-bin"],
            route: "claude/sonnet/medium",
            fallbacks: ["codex/gpt/high"],
            operatorID: "user-op",
            project: SetupInvocation.Project(
                id: "demo", name: "Demo", linearProject: .existing("proj-1"),
                specSource: "~/dev/demo-spec",
                repos: [
                    SetupInvocation.Repo(name: "backend", role: "backend", path: "~/dev/backend", check: "swift test")
                ]
            ),
            jobs: .install
        )

        #expect(try invocation.arguments() == [
            "setup", "--init",
            "--linear-credential", "keychain:linear",
            "--github-credential", "keychain:github",
            "--cli", "claude",
            "--cli", "codex=codex-bin",
            "--route", "claude/sonnet/medium",
            "--fallback", "codex/gpt/high",
            "--operator", "user-op",
            "--project", "demo",
            "--project-name", "Demo",
            "--linear-project", "proj-1",
            "--spec-source", "~/dev/demo-spec",
            "--repo", "backend,backend,~/dev/backend,swift test",
            "--install-jobs"
        ])
    }

    @Test("A minimal invocation is just setup --init")
    func minimalInvocationIsJustInit() throws {
        #expect(try SetupInvocation().arguments() == ["setup", "--init"])
    }

    @Test("nil and empty (after trimming) options are omitted")
    func emptyOptionsAreOmitted() throws {
        let invocation = SetupInvocation(
            linearCredential: nil, githubCredential: "", cliAdapters: ["  ", ""]
        )

        #expect(try invocation.arguments() == ["setup", "--init"])
    }

    @Test("A createInTeam Project passes --linear-team, not --linear-project") // glossary:ignore GL001
    func createInTeamPassesLinearTeam() throws {
        let invocation = SetupInvocation(
            project: SetupInvocation.Project(id: "demo", linearProject: .createInTeam(key: "ENG"))
        )

        #expect(try invocation.arguments() == ["setup", "--init", "--project", "demo", "--linear-team", "ENG"])
    }

    @Test(".notNow passes neither jobs flag")
    func notNowPassesNoJobsFlag() throws {
        #expect(try SetupInvocation(jobs: .notNow).arguments() == ["setup", "--init"])
    }

    @Test(".install passes --install-jobs")
    func installPassesInstallJobs() throws {
        #expect(try SetupInvocation(jobs: .install).arguments() == ["setup", "--init", "--install-jobs"])
    }

    @Test(".export without cron passes --export-jobs only")
    func exportWithoutCronPassesExportJobsOnly() throws {
        let arguments = try SetupInvocation(jobs: .export(directory: "/tmp/jobs", cron: false)).arguments()

        #expect(arguments == ["setup", "--init", "--export-jobs", "/tmp/jobs"])
    }

    @Test(".export with cron also passes --cron")
    func exportWithCronAlsoPassesCron() throws {
        let arguments = try SetupInvocation(jobs: .export(directory: "/tmp/jobs", cron: true)).arguments()

        #expect(arguments == ["setup", "--init", "--export-jobs", "/tmp/jobs", "--cron"])
    }

    @Test("A comma in a Repo's name, role or path is refused", arguments: [
        SetupInvocation.Repo(name: "back,end", role: "backend", path: "~/dev/backend", check: "swift test"),
        SetupInvocation.Repo(name: "backend", role: "back,end", path: "~/dev/backend", check: "swift test"),
        SetupInvocation.Repo(name: "backend", role: "backend", path: "~/dev/back,end", check: "swift test")
    ])
    func commaInRepoFieldIsRefused(repo: SetupInvocation.Repo) {
        let invocation = SetupInvocation(
            project: SetupInvocation.Project(id: "demo", linearProject: .existing("proj-1"), repos: [repo])
        )

        #expect(throws: SetupInvocationError.self) { try invocation.arguments() }
    }

    @Test("An empty Repo field is refused", arguments: [
        SetupInvocation.Repo(name: "", role: "backend", path: "~/dev/backend", check: "swift test"),
        SetupInvocation.Repo(name: "backend", role: "", path: "~/dev/backend", check: "swift test"),
        SetupInvocation.Repo(name: "backend", role: "backend", path: "", check: "swift test"),
        SetupInvocation.Repo(name: "backend", role: "backend", path: "~/dev/backend", check: "")
    ])
    func emptyRepoFieldIsRefused(repo: SetupInvocation.Repo) {
        let invocation = SetupInvocation(
            project: SetupInvocation.Project(id: "demo", linearProject: .existing("proj-1"), repos: [repo])
        )

        #expect(throws: SetupInvocationError.self) { try invocation.arguments() }
    }

    @Test("choicesArguments builds --print-choices with only the Linear options") // glossary:ignore GL001
    func choicesArgumentsBuildsPrintChoices() {
        let arguments = SetupInvocation.choicesArguments(
            linearCredential: "keychain:linear", githubCredential: "keychain:github"
        )

        #expect(arguments == [
            "setup", "--print-choices",
            "--linear-credential", "keychain:linear",
            "--github-credential", "keychain:github"
        ])
    }

    @Test("choicesArguments omits absent options") // glossary:ignore GL001
    func choicesArgumentsOmitsAbsentOptions() {
        let arguments = SetupInvocation.choicesArguments(linearCredential: nil, githubCredential: nil)

        #expect(arguments == ["setup", "--print-choices"])
    }

    @Test("installLinearArguments builds --install-linear --events json") // glossary:ignore GL001
    func installLinearArgumentsBuildsInstallLinear() {
        let arguments = SetupInvocation.installLinearArguments(linearCredential: "keychain:linear")

        #expect(arguments == [
            "setup", "--install-linear", "--events", "json", "--linear-credential", "keychain:linear"
        ])
    }

    @Test("installLinearArguments omits an absent credential") // glossary:ignore GL001
    func installLinearArgumentsOmitsAbsentCredential() {
        let arguments = SetupInvocation.installLinearArguments()

        #expect(arguments == ["setup", "--install-linear", "--events", "json"])
    }

    @Test("installLinearArguments appends --remote when true") // glossary:ignore GL001
    func installLinearArgumentsAppendsRemote() {
        let arguments = SetupInvocation.installLinearArguments(linearCredential: "keychain:linear", remote: true)

        #expect(arguments == [
            "setup", "--install-linear", "--events", "json", "--linear-credential", "keychain:linear", "--remote"
        ])
    }
}
