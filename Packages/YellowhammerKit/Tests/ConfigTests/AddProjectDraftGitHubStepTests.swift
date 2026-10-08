import Config
import Domain
import Testing

@Suite("AddProjectDraft, GitHub step")
struct AddProjectDraftGitHubStepTests {
    private static func report(
        _ state: GitHubCredentialReport.State = .resolves, message: String = "m",
        repos: [GitHubCredentialReport.Repo] = []
    ) -> GitHubCredentialReport {
        GitHubCredentialReport(
            reference: "keychain:github", state: state, login: "octocat", message: message, repos: repos
        )
    }

    private static func repo(
        _ name: String, _ status: GitHubCredentialReport.RepoStatus
    ) -> GitHubCredentialReport.Repo {
        GitHubCredentialReport.Repo(
            name: name, path: "/work/\(name)", slug: "acme/\(name)", status: status,
            message: "Repo \(name): \(status)"
        )
    }

    @Test("The GitHub step follows Repos, and is described")
    func stepOrder() {
        #expect(AddProjectDraft.Step.allCases == [.project, .board, .repos, .github, .specSource, .bounds, .jobs])
        #expect(AddProjectDraft.Step.github.title == "Code Hosting")
        #expect(AddProjectDraft.Step.github.shortTitle == "Code Hosting")
        #expect(AddProjectDraft.Step.github.explanation.contains("pull requests"))
    }

    @Test("With no Repo at all, the step asks for one first")
    func noRepo() {
        let draft = AddProjectDraft()
        #expect(draft.problems(in: .github) == ["Add a working Repo first."])
    }

    @Test("With only a spec-role Repo there is nothing to push to: the credential alone is checked")
    func onlySpecRepo() {
        var draft = AddProjectDraft()
        draft.codeHostingConnectionName = "github"
        draft.codeHostingCheckedConnectionName = "github"
        draft.context.codeHostingConnections = [
            CodeHostingConnection(name: "github", kind: .keychainToken(.init("keychain:github")!))
        ]
        draft.addRepo(path: "/work/spec")
        draft.repos[0].role = "spec"
        #expect(draft.workingRepoPaths.isEmpty)
        #expect(draft.problems(in: .github) == ["Check the Code Hosting Connection."])
        draft.gitHubReport = validGitHubReport(repoPaths: draft.workingRepoPaths)
        draft.gitHubCheckedRepoPaths = []
        #expect(draft.problems(in: .github).isEmpty)
        draft.gitHubReport = Self.report(.missing, message: "no token")
        #expect(draft.problems(in: .github) == ["no token"])
    }

    @Test("An unchecked token is a problem")
    func unchecked() {
        var draft = AddProjectDraft()
        draft.codeHostingConnectionName = "github"
        draft.codeHostingCheckedConnectionName = "github"
        draft.context.codeHostingConnections = [
            CodeHostingConnection(name: "github", kind: .keychainToken(.init("keychain:github")!))
        ]
        draft.addRepo(path: "/work/backend")
        #expect(draft.problems(in: .github) == ["Check the Code Hosting Connection."])
        #expect(draft.summary(of: .github) == "Not checked")
    }

    @Test("A valid report against the current working Repos is no problem")
    func valid() {
        let draft = completeAddProjectDraft()
        #expect(draft.problems(in: .github).isEmpty)
        #expect(draft.summary(of: .github) == "github · GitHub user octocat")
    }

    @Test("Changing the working Repos after the check makes it stale", arguments: ["add", "remove", "move"])
    func staleAfterRepoChange(change: String) {
        var draft = completeAddProjectDraft()
        switch change {
        case "add": draft.addRepo(path: "/work/acme-web")
        case "remove": draft.repos.removeAll()
        default: draft.repos[0].path = "/work/elsewhere"
        }
        if change == "remove" {
            #expect(draft.problems(in: .github) == ["Add a working Repo first."])
        } else {
            #expect(draft.problems(in: .github) == ["Check the Code Hosting Connection."])
        }
    }

    @Test("Paths compare normalized and sorted: ~ and trailing slashes do not make a check stale")
    func normalizedComparison() {
        var draft = AddProjectDraft()
        draft.codeHostingConnectionName = "github"
        draft.codeHostingCheckedConnectionName = "github"
        draft.context.codeHostingConnections = [
            CodeHostingConnection(name: "github", kind: .keychainToken(.init("keychain:github")!))
        ]
        draft.addRepo(path: "~/dev/a")
        draft.addRepo(path: "/work/b/")
        let paths = draft.workingRepoPaths
        draft.gitHubReport = validGitHubReport(repoPaths: draft.workingRepoPaths)
        draft.gitHubCheckedRepoPaths = [
            AddProjectContext.normalizedPath("/work/b"), AddProjectContext.normalizedPath("~/dev/a")
        ]
        #expect(paths.count == 2)
        #expect(draft.problems(in: .github).isEmpty)
    }

    @Test("A spec-role Repo is not a working Repo: changing it does not stale the check")
    func specRepoIgnored() {
        var draft = completeAddProjectDraft()
        draft.addRepo(path: "/work/acme-spec-repo")
        draft.repos[1].role = "spec"
        #expect(draft.workingRepoPaths == ["/work/acme-backend"])
        #expect(draft.problems(in: .github).isEmpty)
    }

    @Test("A report that does not resolve is its own message", arguments: [
        GitHubCredentialReport.State.missing, .unreadable, .rejected, .unreachable
    ])
    func unresolved(state: GitHubCredentialReport.State) {
        var draft = completeAddProjectDraft()
        draft.gitHubReport = Self.report(state, message: "the token is \(state)")
        #expect(draft.problems(in: .github) == ["the token is \(state)"])
    }

    @Test("Each failing Repo's message is a problem; ok and okUnverified are not")
    func failingRepos() {
        var draft = completeAddProjectDraft()
        draft.gitHubReport = Self.report(repos: [
            Self.repo("acme-backend", .ok), Self.repo("b", .okUnverified), Self.repo("c", .noPushPermission),
            Self.repo("d", .notFound)
        ])
        #expect(draft.problems(in: .github) == ["Repo c: noPushPermission", "Repo d: notFound"])
        #expect(draft.summary(of: .github) == "Cannot push to every Repo")
    }
    @Test("A missing selection blocks Add, and changing a checked connection invalidates its verdict")
    func selectionRequiredAndCurrent() {
        var draft = completeAddProjectDraft()
        draft.codeHostingConnectionName = nil
        #expect(draft.problems(in: .github) == ["Choose a Code Hosting Connection."])
        draft.context.codeHostingConnections.append(
            CodeHostingConnection(name: "gh", kind: .githubCLI(executable: nil))
        )
        draft.codeHostingConnectionName = "gh"
        #expect(draft.problems(in: .github) == ["Check the Code Hosting Connection."])
        #expect(!draft.isComplete)
    }

    @Test("A connection removed from the registry cannot reuse a green report")
    func removedSelection() {
        var draft = completeAddProjectDraft()
        draft.context.codeHostingConnections = []
        #expect(draft.problems(in: .github) == ["github is not a connected Code Hosting Connection."])
    }

    @Test("A resolving report must cover each working Repo, while unverified push is accepted")
    func completeRepoCoverage() {
        var draft = completeAddProjectDraft()
        draft.gitHubReport = Self.report()
        #expect(draft.problems(in: .github) == ["Check push access to every working Repo."])
        draft.gitHubReport = Self.report(repos: [Self.repo("acme-backend", .okUnverified)])
        #expect(draft.problems(in: .github).isEmpty)
    }
}
