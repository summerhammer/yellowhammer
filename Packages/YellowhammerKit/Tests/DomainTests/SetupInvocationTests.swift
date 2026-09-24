import Domain
import Testing

struct SetupInvocationTests {
    @Test("A full invocation builds every option, in order")
    func fullInvocationBuildsEveryOption() throws {
        let invocation = SetupInvocation(
            linearClientID: "client-id",
            linearCredential: "keychain:linear",
            githubCredential: "keychain:github",
            cliAdapters: ["claude", "codex=codex-bin"],
            route: "claude/sonnet/medium",
            fallbacks: ["codex/gpt/high"],
            operatorID: "user-op",
            passesSecretOnStandardInput: false,
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
            "--linear-client-id", "client-id",
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
            linearClientID: "  ", linearCredential: nil, githubCredential: "", cliAdapters: ["  ", ""]
        )

        #expect(try invocation.arguments() == ["setup", "--init"])
    }

    @Test("--linear-client-secret-stdin is passed when requested")
    func secretStdinFlagIsPassed() throws {
        let invocation = SetupInvocation(passesSecretOnStandardInput: true)

        #expect(try invocation.arguments() == ["setup", "--init", "--linear-client-secret-stdin"])
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
            linearClientID: "client-id", linearCredential: "keychain:linear",
            githubCredential: "keychain:github", passesSecretOnStandardInput: true
        )

        #expect(arguments == [
            "setup", "--print-choices",
            "--linear-client-id", "client-id",
            "--linear-credential", "keychain:linear",
            "--github-credential", "keychain:github",
            "--linear-client-secret-stdin"
        ])
    }

    @Test("choicesArguments omits absent options") // glossary:ignore GL001
    func choicesArgumentsOmitsAbsentOptions() {
        let arguments = SetupInvocation.choicesArguments(
            linearClientID: nil, linearCredential: nil, githubCredential: nil, passesSecretOnStandardInput: false
        )

        #expect(arguments == ["setup", "--print-choices"])
    }
}
