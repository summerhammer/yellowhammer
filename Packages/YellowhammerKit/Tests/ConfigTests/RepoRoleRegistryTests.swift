import Config
import Domain
import Foundation
import Testing

private let minimalTail = """
[code_hosting.github.connections]
github = { type = "keychain", credential = "keychain:github" }
"""

private func parse(_ head: String) throws(ConfigurationError) -> MachineConfiguration {
    try MachineConfiguration.parse(head + "\n" + minimalTail + "\n", file: "config.toml")
}

private func refusal(_ head: String) -> ConfigurationError? {
    do {
        _ = try parse(head)
        return nil
    } catch {
        return error
    }
}

private func role(_ name: String) -> RepoRole {
    RepoRole(rawValue: name)
}

private func machine(
    repoRoles: [String] = [], routingRoles: [String] = []
) throws -> MachineConfiguration {
    MachineConfiguration(
        repoRoles: repoRoles.map(role),
        cliAdapters: [CLIAdapterDeclaration(name: "claude")],
        routingTable: try routingRoles.map {
            RoutingEntry(repoRole: .role(role($0)), route: try editingRoute("claude", "sonnet"))
        }
    )
}

private func project(
    _ id: String, name: String, roles: [String], overrideRoles: [String] = []
) throws -> ProjectConfiguration {
    try testEditingProject(
        id: id,
        name: name,
        repos: roles.enumerated().map { index, name in
            RepoDeclaration(name: "repo\(index)", path: "~/dev/\(id)-\(index)", role: role(name), check: .none)
        },
        routingOverrides: try overrideRoles.map {
            RoutingEntry(repoRole: .role(role($0)), route: try editingRoute("claude", "sonnet"))
        }
    )
}

// MARK: - Domain

@Suite("Repo Role names")
struct RepoRoleNameTests {
    @Test("The standard Repo Roles are spec, backend, mobile and web, in that order")
    func standard() {
        #expect(RepoRole.standard.map(\.rawValue) == ["spec", "backend", "mobile", "web"])
        #expect(RepoRole.backend.isStandard)
        #expect(!role("infra").isStandard)
    }

    @Test("A valid name is lowercase letters, digits, _ and -, starting with a letter or digit")
    func validNames() {
        for name in ["infra", "firmware", "a", "3d", "ml_ops", "data-eng", "x1"] {
            #expect(RepoRole.isValidName(name), "\(name)")
        }
        for name in ["", "Infra", "my role", "-infra", "_infra", "infra!", "caf\u{e9}", " infra"] {
            #expect(!RepoRole.isValidName(name), "\(name)")
        }
    }
}

// MARK: - Decoder

@Suite("Decoding repo_roles")
struct RepoRoleDecodingTests {
    @Test("Declared Repo Roles load in file order")
    func loadsInOrder() throws {
        let configuration = try parse(#"repo_roles = ["infra", "firmware"]"#)
        #expect(configuration.repoRoles == [role("infra"), role("firmware")])
    }

    @Test("An absent key declares nothing, and an empty array is valid")
    func absentAndEmpty() throws {
        #expect(try parse("").repoRoles.isEmpty)
        #expect(try parse("repo_roles = []").repoRoles.isEmpty)
    }

    @Test("A multi-line array loads, and a refusal names the offending element's line")
    func multiLine() throws {
        let valid = try parse("repo_roles = [\n  \"infra\",\n  \"firmware\",\n]")
        #expect(valid.repoRoles == [role("infra"), role("firmware")])
        let error = refusal("repo_roles = [\n  \"infra\",\n  \"Firmware\",\n]")
        #expect(error?.line == 3)
        #expect(error?.reason == .invalidRepoRoleName("Firmware"))
    }

    @Test("Each refusal reports the element's line, the key repo_roles and its reason")
    func refusals() {
        let cases: [(String, ConfigurationError.Reason)] = [
            (#"repo_roles = "infra""#, .typeMismatch(expected: "array", found: "string")),
            (#"repo_roles = ["infra", 3]"#, .typeMismatch(expected: "string", found: "integer")),
            (#"repo_roles = ["infra", ""]"#, .emptyString),
            (#"repo_roles = ["Infra"]"#, .invalidRepoRoleName("Infra")),
            (#"repo_roles = ["my role"]"#, .invalidRepoRoleName("my role")),
            (#"repo_roles = ["infra", "infra"]"#, .duplicateRepoRole("infra")),
            (#"repo_roles = ["backend"]"#, .duplicateRepoRole("backend")),
            (#"repo_roles = ["spec"]"#, .duplicateRepoRole("spec"))
        ]
        for (head, reason) in cases {
            let error = refusal(head)
            #expect(error?.line == 1, "\(head)")
            #expect(error?.key == "repo_roles", "\(head)")
            #expect(error?.reason == reason, "\(head)")
        }
    }

    @Test("The duplicate messages say whether the role is standard or declared twice")
    func duplicateMessages() {
        #expect(ConfigurationError.Reason.duplicateRepoRole("web").description
            == "Repo Role \"web\" is a standard Repo Role, offered already")
        #expect(ConfigurationError.Reason.duplicateRepoRole("infra").description
            == "Repo Role \"infra\" is declared twice")
    }
}

// MARK: - Renderer

@Suite("Rendering repo_roles")
struct RepoRoleRenderingTests {
    @Test("Declared Repo Roles survive a round-trip with every other registry, and come before the first table")
    func roundTrip() throws {
        let original = MachineConfiguration(
            linearInstallations: [
                LinearInstallation(
                    name: "acme",
                    credential: try editingCredential("keychain:linear-acme"),
                    workspace: BoardObjectID(rawValue: "workspace-1"),
                    appUser: BoardObjectID(rawValue: "app-user-1")
                )
            ],
            codeHostingConnections: [
                CodeHostingConnection(name: "github", kind: .keychainToken(try editingCredential("keychain:github")))
            ],
            repoRoles: [role("infra"), role("firmware")],
            cliAdapters: [CLIAdapterDeclaration(name: "claude", executable: "/opt/bin/claude")],
            routingTable: [RoutingEntry(repoRole: .role(role("infra")), route: try editingRoute("claude", "sonnet"))]
        )
        let text = original.renderedTOML
        let parsed = try MachineConfiguration.parse(text, file: "config.toml")
        #expect(parsed.repoRoles == [role("infra"), role("firmware")])
        #expect(parsed == original)

        let rolesLine = try #require(text.range(of: #"repo_roles = ["infra", "firmware"]"#))
        let firstTable = try #require(text.range(of: "["))
        #expect(rolesLine.lowerBound < firstTable.lowerBound)
        #expect(text.hasPrefix(#"repo_roles = ["infra", "firmware"]"#))
    }

    @Test("A machine with no declared Repo Roles renders no repo_roles line")
    func noRolesNoLine() throws {
        #expect(!(try machine().renderedTOML.contains("repo_roles")))
    }
}

// MARK: - Editing helpers

@Suite("Declaring Repo Roles")
struct RepoRoleEditingTests {
    @Test("declaring trims and appends after the existing declarations")
    func declaring() throws {
        let declared = try machine(repoRoles: ["infra"]).declaring(repoRole: "  firmware \n")
        #expect(declared.repoRoles == [role("infra"), role("firmware")])
    }

    @Test("removing drops only that Repo Role")
    func removing() throws {
        let removed = try machine(repoRoles: ["infra", "firmware"]).removing(repoRole: role("infra"))
        #expect(removed.repoRoles == [role("firmware")])
        #expect(try machine(repoRoles: ["infra"]).removing(repoRole: role("web")).repoRoles == [role("infra")])
    }

    @Test("declarationProblem is nil for a name that can be declared, trimmed")
    func noProblem() throws {
        #expect(try machine(repoRoles: ["infra"]).declarationProblem(forRepoRoleNamed: " firmware ") == nil)
    }

    @Test("declarationProblem says why a name cannot be declared")
    func problems() throws {
        let configured = try machine(repoRoles: ["infra"])
        let empty = try #require(configured.declarationProblem(forRepoRoleNamed: "  "))
        #expect(empty.contains("name"))
        let invalid = try #require(configured.declarationProblem(forRepoRoleNamed: "My Role"))
        #expect(invalid.contains("lowercase letters, digits"))
        #expect(invalid.contains("start with a letter or a digit"))
        let standard = try #require(configured.declarationProblem(forRepoRoleNamed: "backend"))
        #expect(standard.contains("standard Repo Role"))
        #expect(standard.contains("offered already"))
        let duplicate = try #require(configured.declarationProblem(forRepoRoleNamed: "infra"))
        #expect(duplicate.contains("already declared"))
    }

    @Test("offeredRepoRoles is the standard four, then the declared ones, each once")
    func offered() throws {
        #expect(try machine().offeredRepoRoles == RepoRole.standard)
        #expect(try machine(repoRoles: ["infra", "firmware"]).offeredRepoRoles
            == RepoRole.standard + [role("infra"), role("firmware")])
        // A hand-built machine can repeat a role; the loader would refuse it, the pickers still show it once.
        #expect(try machine(repoRoles: ["infra", "infra", "web"]).offeredRepoRoles
            == RepoRole.standard + [role("infra")])
    }

    @Test("offeredRepoRoles(with:) unions declared, Repo, base-routing and override roles; standard first, rest sorted")
    func offeredWithProjects() throws {
        let configured = try machine(repoRoles: ["zeta", "infra"], routingRoles: ["base-only", "web"])
        let projects = [
            try project("one", name: "One", roles: ["backend", "projectonly", "infra"]),
            try project("two", name: "Two", roles: ["spec"], overrideRoles: ["override-only", "projectonly"])
        ]
        let offered = configured.offeredRepoRoles(with: projects)
        #expect(offered.map(\.rawValue) == [
            "spec", "backend", "mobile", "web",
            "base-only", "infra", "override-only", "projectonly", "zeta"
        ])
        #expect(try machine().offeredRepoRoles(with: []) == RepoRole.standard)
    }

    @Test("projectsUsing names each Project once, in order, by Repo or override")
    func projectsUsing() throws {
        let projects = [
            try project("one", name: "One", roles: ["infra", "infra"]),
            try project("two", name: "Two", roles: ["backend"], overrideRoles: ["infra"]),
            try project("three", name: "Three", roles: ["backend"])
        ]
        let configured = try machine(repoRoles: ["infra"])
        #expect(configured.projectsUsing(repoRole: role("infra"), in: projects) == ["One", "Two"])
        #expect(configured.projectsUsing(repoRole: .backend, in: projects) == ["Two", "Three"])
        #expect(configured.projectsUsing(repoRole: role("firmware"), in: projects).isEmpty)
    }

    @Test("baseRoutingTableNames(repoRole:) matches a base entry that names the role")
    func baseRoutingTableNames() throws {
        let configured = try machine(routingRoles: ["infra"])
        #expect(configured.baseRoutingTableNames(repoRole: role("infra")))
        #expect(!configured.baseRoutingTableNames(repoRole: role("firmware")))
        let wildcard = MachineConfiguration(
            cliAdapters: [CLIAdapterDeclaration(name: "claude")],
            routingTable: [RoutingEntry(route: try editingRoute("claude", "sonnet"))]
        )
        #expect(!wildcard.baseRoutingTableNames(repoRole: role("infra")))
    }
}

// MARK: - Non-validating registry

@Suite("The Repo Role registry does not validate")
struct RepoRoleRegistryRegressionTests {
    @Test("A Project whose Repo has an undeclared Repo Role still loads")
    func undeclaredRoleLoads() throws {
        let repo = RepoDeclaration(name: "ops", path: "~/dev/acme-ops", role: role("infra"), check: .none)
        let directory = try makeEditingDirectory(
            machine: try testEditingMachine(),
            projects: [try testEditingProject(id: "acme", repos: [repo])]
        )
        defer { cleanupEditingDirectory(directory) }

        let configuration = try Configuration.load(directory: directory)
        #expect(configuration.projects.map(\.id.rawValue) == ["acme"])
        #expect(configuration.projects.first?.repos.first?.role == role("infra"))
        #expect(configuration.machine.repoRoles.isEmpty)
    }

    @Test("A Routing Entry naming an undeclared Repo Role still loads")
    func undeclaredRoutingRoleLoads() throws {
        let toml = """
        [cli.claude]

        [code_hosting.github.connections]
        github = { type = "keychain", credential = "keychain:github" }

        [[routing]]
        repo_role = "infra"
        route = "claude/sonnet"
        """
        let configuration = try MachineConfiguration.parse(toml, file: "config.toml")
        #expect(configuration.routingTable.first?.repoRole == .role(role("infra")))
    }
}

// MARK: - Add Project wizard

@Suite("The Add Project wizard offers declared Repo Roles")
struct AddProjectRepoRoleTests {
    @Test("The memberwise default offers the standard four")
    func defaultOffer() {
        #expect(AddProjectContext().repoRoles == ["spec", "backend", "mobile", "web"])
    }

    @Test("A context built from a configuration offers the union")
    func fromConfiguration() throws {
        let directory = try makeEditingDirectory(
            machine: try testEditingMachine().declaring(repoRole: "firmware"),
            projects: [
                try testEditingProject(id: "acme", repos: [
                    RepoDeclaration(name: "ops", path: "~/dev/acme-ops", role: role("infra"), check: .none)
                ])
            ]
        )
        defer { cleanupEditingDirectory(directory) }
        let configuration = try Configuration.load(directory: directory)

        let context = AddProjectContext(configuration: configuration, projectFileIDs: [], journalProjectIDs: [])
        #expect(context.repoRoles == ["spec", "backend", "mobile", "web", "firmware", "infra"])
    }

    @Test("guessedRole reads the context: a declared infra is guessed, an undeclared one is not")
    func guessReadsContext() {
        var draft = AddProjectDraft()
        #expect(draft.guessedRole(for: "~/dev/acme/acme-infra") == "")
        draft.context.repoRoles.append("infra")
        #expect(draft.guessedRole(for: "~/dev/acme/acme-infra") == "infra")
        #expect(draft.guessedRole(for: "~/dev/acme/acme-infra/") == "infra")
        draft.addRepo(path: "~/dev/acme/acme-infra")
        #expect(draft.repos.map(\.role) == ["infra"])
    }

    @Test("The longest matching Repo Role wins")
    func longestMatchWins() {
        var draft = AddProjectDraft()
        draft.context.repoRoles = ["web", "mobile-web", "spec"]
        #expect(draft.guessedRole(for: "/w/acme-mobile-web") == "mobile-web")
        #expect(draft.guessedRole(for: "/w/acme-web") == "web")
    }

    @Test("workingRole never returns spec")
    func workingRoleNeverSpec() {
        var draft = AddProjectDraft()
        draft.context.repoRoles = ["spec", "specs", "infra"]
        #expect(draft.guessedRole(for: "/w/acme-spec") == "spec")
        #expect(draft.workingRole(for: "/w/acme-spec") == "")
        #expect(draft.workingRole(for: "/w/acme-infra") == "infra")
    }
}
