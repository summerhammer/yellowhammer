import Domain

/// The values a form edits, as the Operator typed them, before the loader has had a chance to look at
/// them. Every field is a raw `String` (or an array of them): the loader is the single validator, and
/// every refusal the app shows the Operator carries the loader's own message
/// (``ConfigurationEditError/refused(_:)``), never a second, app-side opinion of what is valid.
public struct RouteDraft: Hashable, Sendable {
    public var cli: String
    public var model: String
    public var effort: String

    public init(cli: String, model: String, effort: String) {
        self.cli = cli
        self.model = model
        self.effort = effort
    }

    public init(_ route: Route) {
        self.init(cli: route.cli, model: route.model, effort: route.effort)
    }
}

/// One `[[routing]]` entry's fields as typed: `kind` and `repo_role` are `""` for "not set" (renders as
/// `*` / omitted, per ``RoutingEntry``'s own defaults), so the loader — not the draft — decides whether
/// an empty or garbage value is valid.
public struct RoutingEntryDraft: Equatable, Sendable {
    public var kind: String
    public var repoRole: String
    public var route: RouteDraft
    /// In the order they are tried.
    public var fallbacks: [RouteDraft]

    public init(kind: String = "", repoRole: String = "", route: RouteDraft, fallbacks: [RouteDraft] = []) {
        self.kind = kind
        self.repoRole = repoRole
        self.route = route
        self.fallbacks = fallbacks
    }

    public init(_ entry: RoutingEntry) {
        let repoRole: String
        switch entry.repoRole {
        case .any: repoRole = ""
        case .role(let role): repoRole = role.rawValue
        }
        self.init(
            kind: entry.kind == .any ? "" : entry.kind.description,
            repoRole: repoRole,
            route: RouteDraft(entry.route),
            fallbacks: entry.fallbacks.map(RouteDraft.init)
        )
    }
}

/// One `[[repos]]` entry's fields as typed. `check` is `"none"` for the declared no-check, matching
/// ``Check/description``.
public struct RepoDraft: Equatable, Sendable {
    public var name: String
    public var path: String
    public var role: String
    public var check: String
    public var protectedPaths: [String]

    public init(name: String, path: String, role: String, check: String, protectedPaths: [String] = []) {
        self.name = name
        self.path = path
        self.role = role
        self.check = check
        self.protectedPaths = protectedPaths
    }

    public init(_ repo: RepoDeclaration) {
        self.init(
            name: repo.name,
            path: repo.path,
            role: repo.role.rawValue,
            check: repo.check.description,
            protectedPaths: repo.protectedPaths
        )
    }
}

/// A Project's six Bounds, as typed strings, so a garbage value (`"0"`, `"abc"`) reaches the loader
/// instead of being coerced or refused a second time here.
public struct BoundsDraft: Equatable, Sendable {
    public var reviewRoundsMax: String
    public var attemptsPerWorkCard: String
    public var unansweredNightsMax: String
    public var reselectionsMax: String
    public var consecutiveRefusalsMax: String
    public var failedAdoptionsMax: String

    public init(
        reviewRoundsMax: String,
        attemptsPerWorkCard: String,
        unansweredNightsMax: String,
        reselectionsMax: String,
        consecutiveRefusalsMax: String,
        failedAdoptionsMax: String
    ) {
        self.reviewRoundsMax = reviewRoundsMax
        self.attemptsPerWorkCard = attemptsPerWorkCard
        self.unansweredNightsMax = unansweredNightsMax
        self.reselectionsMax = reselectionsMax
        self.consecutiveRefusalsMax = consecutiveRefusalsMax
        self.failedAdoptionsMax = failedAdoptionsMax
    }

    public init(_ bounds: Bounds) {
        self.init(
            reviewRoundsMax: String(bounds.reviewRoundsMax),
            attemptsPerWorkCard: String(bounds.attemptsPerWorkCard),
            unansweredNightsMax: String(bounds.unansweredNightsMax),
            reselectionsMax: String(bounds.reselectionsMax),
            consecutiveRefusalsMax: String(bounds.consecutiveRefusalsMax),
            failedAdoptionsMax: String(bounds.failedAdoptionsMax)
        )
    }
}

/// A Project file's fields, editable through the app's form: the Operator edits every field but the
/// identity (``id``) and the Spec Source (``specSource``, shown read-only — the app never edits it),
/// as strings, and ``renderedTOML`` is handed to the loader (``Configuration/save(_:to:in:replacing:)``)
/// to validate. ``schedule``, ``gitHubCredential``, ``changeType`` and the Message Templates are carried
/// through untouched: this slice of the app does not edit them. A key whose value is its default is not
/// written back (``renderedTOML``).
public struct ProjectFileDraft: Equatable, Sendable {
    public let id: ProjectID
    public var name: String
    public var linearInstallationName: String
    public var linearProject: String
    /// The Spec Source path, as written. Read-only: nil when the specification source is a Repo of
    /// Repo Role `spec` instead.
    public let specSource: String?
    public var repos: [RepoDraft]
    public var bounds: BoundsDraft
    public var routingOverrides: [RoutingEntryDraft]
    var schedule: Schedule
    var gitHubCredential: CredentialReference?
    var changeType: ChangeType
    var pullRequestTitle: MessageTemplate
    var commitMessage: MessageTemplate
    var wipCommitMessage: MessageTemplate

    public init(_ project: ProjectConfiguration) {
        id = project.id
        name = project.name
        linearInstallationName = project.linearInstallationName
        linearProject = project.linearProject
        specSource = project.specSource
        repos = project.repos.map(RepoDraft.init)
        bounds = BoundsDraft(project.bounds)
        routingOverrides = project.routingOverrides.map(RoutingEntryDraft.init)
        schedule = project.schedule
        gitHubCredential = project.gitHubCredential
        changeType = project.changeType
        pullRequestTitle = project.pullRequestTitle
        commitMessage = project.commitMessage
        wipCommitMessage = project.wipCommitMessage
    }
}

extension ProjectFileDraft {
    /// Renders the draft's fields back to the TOML shapes ``ConfigurationDecoding`` accepts — see
    /// ``ConfigurationRendering`` for the escaping and per-field rendering rules. The loader is the only
    /// validator: a value the Operator typed that the loader refuses is rendered anyway, and reported
    /// through the loader's own error.
    public var renderedTOML: String {
        var sections: [String] = []

        var top = ["id = \(ConfigurationRendering.quoted(id.rawValue))"]
        top.append("name = \(ConfigurationRendering.quoted(name))")
        if let specSource {
            top.append("spec_source = \(ConfigurationRendering.quoted(specSource))")
        }
        if changeType != .feat {
            top.append("change_type = \(ConfigurationRendering.quoted(changeType.rawValue))")
        }
        sections.append(top.joined(separator: "\n"))

        sections.append([
            "[board.linear]",
            "connection = \(ConfigurationRendering.quoted(linearInstallationName))",
            "project = \(ConfigurationRendering.quoted(linearProject))" // glossary:ignore GL001
        ].joined(separator: "\n"))

        var github: [String] = []
        if let gitHubCredential {
            github.append("credential = \(ConfigurationRendering.quoted(gitHubCredential.rawValue))")
        }
        if let line = ConfigurationRendering.templateLine(pullRequestTitle) {
            github.append(line)
        }
        if !github.isEmpty {
            sections.append((["[github]"] + github).joined(separator: "\n"))
        }
        let git = [commitMessage, wipCommitMessage].compactMap(ConfigurationRendering.templateLine)
        if !git.isEmpty {
            sections.append((["[git]"] + git).joined(separator: "\n"))
        }

        for repo in repos {
            sections.append(ConfigurationRendering.renderedRepo(repo))
        }

        sections.append(ConfigurationRendering.renderedLimits(bounds))
        sections.append(ConfigurationRendering.renderedSchedule(schedule))

        sections.append(contentsOf: ConfigurationRendering.routingSection(routingOverrides))

        return sections.joined(separator: "\n\n") + "\n"
    }
}

extension MachineConfiguration {
    /// Renders one `[board.linear.connections.<name>]` table per Board Connection, `[github]`, one `[cli.<name>]` table per declared adapter and the given base
    /// Routing Table, in the shape ``MachineConfigurationDecoder`` reads back. Everything but the
    /// Routing Table is carried from `self`.
    public func renderedTOML(routingTable: [RoutingEntryDraft]) -> String {
        var sections: [String] = []

        for installation in linearInstallations {
            var lines = [
                ConfigurationRendering.installationHeader(installation.name),
                "credential = \(ConfigurationRendering.quoted(installation.credential.rawValue))",
                "workspace = \(ConfigurationRendering.quoted(installation.workspace.rawValue))",
                "yellowhammer_identity = \(ConfigurationRendering.quoted(installation.appUser.rawValue))"
            ]
            if let operatorIdentity = installation.operatorIdentity {
                lines.append("operator = \(ConfigurationRendering.quoted(operatorIdentity.rawValue))")
            }
            sections.append(lines.joined(separator: "\n"))
        }

        sections.append("[github]\ncredential = \(ConfigurationRendering.quoted(gitHubCredential.rawValue))")

        for adapter in cliAdapters {
            var lines = ["[cli.\(ConfigurationRendering.quotedKey(adapter.name))]"]
            if let executable = adapter.executable {
                lines.append("executable = \(ConfigurationRendering.quoted(executable))")
            }
            sections.append(lines.joined(separator: "\n"))
        }

        sections.append(contentsOf: ConfigurationRendering.routingSection(routingTable))

        return sections.joined(separator: "\n\n") + "\n"
    }
}
