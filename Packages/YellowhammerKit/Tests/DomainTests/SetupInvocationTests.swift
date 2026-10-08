import Domain
import Testing

struct SetupInvocationTests {
    @Test("The schedule flags follow --spec-source and precede --repo, only when set")
    func scheduleFlagsPositionAndOmission() throws {
        let repo = SetupInvocation.Repo(name: "backend", role: "backend", path: "~/b", check: "none")
        let set = SetupInvocation(project: SetupInvocation.Project(
            id: "demo", linearProject: .existing("proj-1"), specSource: "~/spec", repos: [repo],
            nightStart: "23:00", nightEnd: "05:30", buildEveryMinutes: 20
        ))
        let arguments = try set.arguments()
        let tail = Array(arguments.suffix(10))
        #expect(tail == [
            "--spec-source", "~/spec", "--night-start", "23:00", "--night-end", "05:30",
            "--build-every-minutes", "20", "--repo", "backend,backend,~/b,none"
        ])
        let unset = SetupInvocation(project: SetupInvocation.Project(id: "demo", linearProject: .existing("proj-1")))
        let plain = try unset.arguments()
        #expect(!plain.contains("--night-start") && !plain.contains("--night-end"))
        #expect(!plain.contains("--build-every-minutes"))
    }

    @Test("A full invocation builds every option, in order")
    func fullInvocationBuildsEveryOption() throws {
        let invocation = SetupInvocation(
            boardConnection: "main",
            codeHostingConnection: "acme",
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
            "--board-connection", "main",
            "--code-hosting-connection", "acme",
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
            boardConnection: nil, codeHostingConnection: "", cliAdapters: ["  ", ""]
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
        let arguments = SetupInvocation.choicesArguments(boardConnection: "main")

        #expect(arguments == ["setup", "--print-choices", "--board-connection", "main"])
    }

    @Test("choicesArguments omits absent options") // glossary:ignore GL001
    func choicesArgumentsOmitsAbsentOptions() {
        let arguments = SetupInvocation.choicesArguments(boardConnection: nil)

        #expect(arguments == ["setup", "--print-choices"])
    }

    @Test("choicesArguments passes --linear-project when provided") // glossary:ignore GL001
    func choicesArgumentsPassesLinearProject() {
        let arguments = SetupInvocation.choicesArguments(
            boardConnection: "main", linearProject: "proj-1"
        )

        #expect(arguments == [
            "setup", "--print-choices",
            "--board-connection", "main",
            "--linear-project", "proj-1"
        ])
    }

    @Test("installLinearArguments builds --install-linear --events json") // glossary:ignore GL001
    func installLinearArgumentsBuildsInstallLinear() {
        let arguments = SetupInvocation.installLinearArguments(boardConnection: "main")

        #expect(arguments == [
            "setup", "--install-linear", "--events", "json", "--board-connection", "main"
        ])
    }

    @Test("installLinearArguments omits an absent credential") // glossary:ignore GL001
    func installLinearArgumentsOmitsAbsentCredential() {
        let arguments = SetupInvocation.installLinearArguments()

        #expect(arguments == ["setup", "--install-linear", "--events", "json"])
    }

    @Test("installLinearArguments appends --board-connection-name, omitting an empty one")
    func installLinearArgumentsAppendsInstallationName() {
        #expect(SetupInvocation.installLinearArguments(boardConnectionName: "work") == [
            "setup", "--install-linear", "--events", "json", "--board-connection-name", "work" // glossary:ignore GL001
        ])
        #expect(SetupInvocation.installLinearArguments(boardConnectionName: "  ") == [
            "setup", "--install-linear", "--events", "json" // glossary:ignore GL001
        ])
    }

    @Test("An --init invocation passes --board-connection-name after --board-connection")
    func initPassesInstallationName() throws {
        let invocation = SetupInvocation(boardConnectionName: "work")
        #expect(try invocation.arguments() == ["setup", "--init", "--board-connection-name", "work"])
    }

    @Test("installLinearArguments appends --remote when true") // glossary:ignore GL001
    func installLinearArgumentsAppendsRemote() {
        let arguments = SetupInvocation.installLinearArguments(boardConnection: "main", remote: true)

        #expect(arguments == [
            "setup", "--install-linear", "--events", "json", "--board-connection", "main", "--remote"
        ])
    }

    @Test("Code Hosting check invocation uses the config report command")
    func checkCodeHostingCredentialArguments() {
        #expect(SetupInvocation.checkCodeHostingCredentialArguments(connection: nil, repoPaths: [])
            == ["config", "check-code-hosting-credential"])
        #expect(SetupInvocation.checkCodeHostingCredentialArguments(
            connection: "acme", repoPaths: ["~/a", "~/b"]
        ) == [
            "config", "check-code-hosting-credential", "--connection", "acme",
            "--github-repo", "~/a", "--github-repo", "~/b"
        ])
    }

    @Test("Code Hosting token invocations choose connect or replace and never include the token")
    func codeHostingTokenArguments() {
        #expect(SetupInvocation.codeHostingTokenArguments(connection: "acme", source: .standardInput, replace: false)
            == ["config", "connect-code-hosting", "acme", "--token-stdin"])
        #expect(SetupInvocation.codeHostingTokenArguments(connection: "acme", source: .githubCLI, replace: true)
            == ["config", "replace-code-hosting-token", "acme", "--from-gh"])
    }

    @Test("connectGitHubCLIArguments connects the gh CLI itself under the local name")
    func connectGitHubCLIArguments() {
        #expect(SetupInvocation.connectGitHubCLIArguments(connection: "gh")
            == ["config", "connect-code-hosting", "gh", "--gh-cli"])
    }
}
