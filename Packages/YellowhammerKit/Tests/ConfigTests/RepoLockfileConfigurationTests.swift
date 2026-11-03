import Config
import Domain
import Testing

private func project(lockfile: String?) throws -> ProjectConfiguration {
    ProjectConfiguration(
        id: try #require(ProjectID(rawValue: "lockfile")),
        name: "Lockfile",
        linearInstallationName: "acme",
        linearProject: "LF",
        codeHostingConnectionName: "github",
        specSource: "~/dev/lf-spec",
        repos: [RepoDeclaration(
            name: "web", path: "~/dev/web", role: .backend, check: .none, lockfile: lockfile
        )]
    )
}

@Test("A repo's lockfile renders, round-trips through parse, and reaches the Domain Repo")
func repoLockfileRoundTrips() throws {
    let configuration = try project(lockfile: "pnpm-lock.yaml")
    #expect(configuration.renderedTOML.contains("lockfile = \"pnpm-lock.yaml\""))
    let parsed = try ProjectConfiguration.parse(configuration.renderedTOML, file: "lockfile.toml")
    #expect(parsed == configuration)
    #expect(parsed.repos.first?.lockfile == "pnpm-lock.yaml")
    #expect(parsed.projectRepositories.workingRepos.first?.lockfile == "pnpm-lock.yaml")
}

@Test("A repo with no lockfile key has none and renders no line")
func repoLockfileAbsentIsNil() throws {
    let configuration = try project(lockfile: nil)
    #expect(!configuration.renderedTOML.contains("lockfile ="))
    let parsed = try ProjectConfiguration.parse(configuration.renderedTOML, file: "no-lockfile.toml")
    #expect(parsed.repos.first?.lockfile == nil)
    #expect(parsed.projectRepositories.workingRepos.first?.lockfile == nil)
}

@Test("A lockfile that is not a plain repository-relative path is refused", arguments: [
    "/abs/pnpm-lock.yaml", "~/x", "a/../b", "../up", "*.lock", "locks/?.lock", "locks/[a].lock"
])
func repoLockfileInvalidFormsAreRefused(_ lockfile: String) throws {
    let toml = try project(lockfile: "ok.lock").renderedTOML
        .replacing("lockfile = \"ok.lock\"", with: "lockfile = \"\(lockfile)\"")
    do {
        _ = try ProjectConfiguration.parse(toml, file: "bad-lockfile.toml")
        Issue.record("expected \(lockfile) to be refused")
    } catch {
        #expect(error.key == "repos[0].lockfile", "\(error)")
        #expect(error.reason == .invalidLockfilePath(lockfile), "\(error)")
    }
}

@Test("An empty lockfile is refused as an empty string")
func repoLockfileEmptyIsRefused() throws {
    let toml = try project(lockfile: "ok.lock").renderedTOML
        .replacing("lockfile = \"ok.lock\"", with: "lockfile = \"\"")
    do {
        _ = try ProjectConfiguration.parse(toml, file: "empty-lockfile.toml")
        Issue.record("expected an empty lockfile to be refused")
    } catch {
        #expect(error.key == "repos[0].lockfile", "\(error)")
        #expect(error.reason == .emptyString, "\(error)")
    }
}
