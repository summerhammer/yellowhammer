import Foundation

/// The `yh` argument vector the app runs to do everything `yh setup` does on the Operator's behalf
/// (P14.2): the flag spelling lives here, next to `SetupCommand`'s own contract, so the app and the
/// parser can never drift apart.
public struct SetupInvocation: Equatable, Sendable {
    /// One `--repo name,role,path,check` declaration. `check == "none"` is the declared no-op Check.
    public struct Repo: Equatable, Sendable {
        public var name: String
        public var role: String
        public var path: String
        public var check: String

        public init(name: String, role: String, path: String, check: String) {
            self.name = name
            self.role = role
            self.path = path
            self.check = check
        }
    }

    /// How the Project's Linear project is named: an existing one, or one to create in a team.
    public enum LinearProject: Equatable, Sendable {
        case existing(String)
        case createInTeam(key: String)
    }

    /// A Project to generate, matching `--project` and its dependent options.
    public struct Project: Equatable, Sendable {
        public var id: String
        public var name: String?
        public var linearProject: LinearProject
        public var specSource: String?
        public var repos: [Repo]
        /// `--night-start HH:MM`, `--night-end HH:MM`, `--build-every-minutes N`: the `[schedule]` window.
        /// Nil means the flag is not passed and the field keeps its default.
        public var nightStart: String?
        public var nightEnd: String?
        public var buildEveryMinutes: Int?

        public init(
            id: String, name: String? = nil, linearProject: LinearProject,
            specSource: String? = nil, repos: [Repo] = [],
            nightStart: String? = nil, nightEnd: String? = nil, buildEveryMinutes: Int? = nil
        ) {
            self.nightStart = nightStart
            self.nightEnd = nightEnd
            self.buildEveryMinutes = buildEveryMinutes
            self.id = id
            self.name = name
            self.linearProject = linearProject
            self.specSource = specSource
            self.repos = repos
        }
    }

    /// What `yh setup` does with the scheduled jobs it generates.
    public enum Jobs: Equatable, Sendable {
        /// Neither `--install-jobs` nor `--export-jobs` is passed.
        case notNow
        case install
        case export(directory: String, cron: Bool)
    }

    /// The local name of the Board Connection the run acts on (`--board-connection`).
    public var boardConnection: String?
    /// The local name for a NEW Board Connection (`--board-connection-name`); never combined with
    /// `boardConnection`. Omitted when nil or trimmed empty (the proposal is used).
    public var boardConnectionName: String?
    /// The local name of the Code Hosting Connection the written Project selects (`--code-hosting-connection`).
    public var codeHostingConnection: String?
    /// `"name"` or `"name=executable"`, in `--cli` order.
    public var cliAdapters: [String]
    public var route: String?
    /// `"cli/model/effort"`, in `--fallback` order.
    public var fallbacks: [String]
    public var operatorID: String?
    public var project: Project?
    public var jobs: Jobs

    public init(
        boardConnection: String? = nil,
        boardConnectionName: String? = nil,
        codeHostingConnection: String? = nil,
        cliAdapters: [String] = [],
        route: String? = nil,
        fallbacks: [String] = [],
        operatorID: String? = nil,
        project: Project? = nil,
        jobs: Jobs = .notNow
    ) {
        self.boardConnection = boardConnection
        self.boardConnectionName = boardConnectionName
        self.codeHostingConnection = codeHostingConnection
        self.cliAdapters = cliAdapters
        self.route = route
        self.fallbacks = fallbacks
        self.operatorID = operatorID
        self.project = project
        self.jobs = jobs
    }

    /// `["setup", "--init", ...]`, the app's non-interactive `yh setup` invocation.
    public func arguments() throws(SetupInvocationError) -> [String] {
        var arguments = ["setup", "--init"]
        Self.appendOption(&arguments, "--board-connection", boardConnection)
        Self.appendOption(&arguments, "--board-connection-name", boardConnectionName)
        Self.appendOption(&arguments, "--code-hosting-connection", codeHostingConnection)
        Self.appendRepeated(&arguments, "--cli", cliAdapters)
        Self.appendOption(&arguments, "--route", route)
        Self.appendRepeated(&arguments, "--fallback", fallbacks)
        Self.appendOption(&arguments, "--operator", operatorID)
        if let project {
            arguments += ["--project", project.id]
            Self.appendOption(&arguments, "--project-name", project.name)
            switch project.linearProject {
            case .existing(let id):
                Self.appendOption(&arguments, "--linear-project", id) // glossary:ignore GL001
            case .createInTeam(let key):
                Self.appendOption(&arguments, "--linear-team", key)
            }
            Self.appendOption(&arguments, "--spec-source", project.specSource)
            Self.appendOption(&arguments, "--night-start", project.nightStart)
            Self.appendOption(&arguments, "--night-end", project.nightEnd)
            if let minutes = project.buildEveryMinutes {
                arguments += ["--build-every-minutes", String(minutes)]
            }
            for repo in project.repos {
                arguments += ["--repo", try Self.repoArgument(repo)]
            }
        }
        switch jobs {
        case .notNow:
            break
        case .install:
            arguments.append("--install-jobs")
        case .export(let directory, let cron):
            arguments += ["--export-jobs", directory]
            if cron { arguments.append("--cron") }
        }
        return arguments
    }

    /// `["setup", "--print-choices", ...]`: never prompts, writes no configuration file.
    public static func choicesArguments(
        boardConnection: String?, linearProject: String? = nil
    ) -> [String] {
        var arguments = ["setup", "--print-choices"] // glossary:ignore GL001
        appendOption(&arguments, "--board-connection", boardConnection)
        appendOption(&arguments, "--linear-project", linearProject)
        return arguments
    }

    /// `["setup", "--install-linear", "--events", "json", ...]`: the app's re-run of just the Linear
    /// step (P17.6 slice (b)) — used both for the first install and for the app's own Retry/Cancel on a
    /// `portsBusy`/`cancelled`/`notCompleted` event, which re-runs this exact invocation. `boardConnection`
    /// selects an existing Board Connection to re-connect; `boardConnectionName` names a new one (an empty
    /// value means "use the proposal"); the two are never passed together.
    public static func installLinearArguments(
        boardConnection: String? = nil, boardConnectionName: String? = nil, remote: Bool = false
    ) -> [String] {
        var arguments = ["setup", "--install-linear", "--events", "json"] // glossary:ignore GL001
        appendOption(&arguments, "--board-connection", boardConnection)
        appendOption(&arguments, "--board-connection-name", boardConnectionName)
        if remote { arguments.append("--remote") }
        return arguments
    }

    /// The token source for a Code Hosting Connection.
    public enum GitHubTokenSource: Equatable, Sendable {
        /// `--token-stdin`: one line on standard input, which the app writes and closes.
        case standardInput
        /// `--from-gh`: the GitHub CLI's `gh auth token`.
        case githubCLI
    }

    /// Checks the selected Keychain token and optional Repos; prints one ``GitHubCredentialReport`` line.
    public static func checkCodeHostingCredentialArguments(
        connection: String?, repoPaths: [String]
    ) -> [String] {
        var arguments = ["config", "check-code-hosting-credential"]
        appendOption(&arguments, "--connection", connection)
        appendRepeated(&arguments, "--github-repo", repoPaths)
        return arguments
    }

    /// Connects a new Keychain token under the given local name, or replaces that connection's token.
    public static func codeHostingTokenArguments(
        connection: String, source: GitHubTokenSource, replace: Bool
    ) -> [String] {
        var arguments = ["config", replace ? "replace-code-hosting-token" : "connect-code-hosting", connection]
        switch source {
        case .standardInput: arguments.append("--token-stdin")
        case .githubCLI: arguments.append("--from-gh")
        }
        return arguments
    }

    public static let codeHostingConnectionsArguments = ["config", "print-code-hosting-connections"]

    /// Selects or changes a Project's Code Hosting Connection (`yh project set-code-hosting-connection <project> <connection>`).
    public static func setProjectCodeHostingConnectionArguments(
        project: String, connection: String
    ) -> [String] {
        ["project", "set-code-hosting-connection", project, connection]
    }

    /// `"name,role,path,check"`. `name`, `role` and `path` may not contain a comma — `--repo` splits on
    /// the first three only, so a comma there would silently corrupt a later field — and none of the
    /// four may be empty.
    private static func repoArgument(_ repo: Repo) throws(SetupInvocationError) -> String {
        try requireNonEmpty(repo.name, field: "name")
        try requireNonEmpty(repo.role, field: "role")
        try requireNonEmpty(repo.path, field: "path")
        try requireNonEmpty(repo.check, field: "check")
        try requireNoComma(repo.name, field: "name")
        try requireNoComma(repo.role, field: "role")
        try requireNoComma(repo.path, field: "path")
        return "\(repo.name),\(repo.role),\(repo.path),\(repo.check)"
    }

    private static func requireNonEmpty(_ value: String, field: String) throws(SetupInvocationError) {
        guard value.isEmpty else { return }
        throw SetupInvocationError("a Repo's \(field) must not be empty")
    }

    private static func requireNoComma(_ value: String, field: String) throws(SetupInvocationError) {
        guard value.contains(",") else { return }
        throw SetupInvocationError("a Repo's \(field) must not contain a comma")
    }

    /// Omitted when nil, or when trimmed empty.
    private static func appendOption(_ arguments: inout [String], _ flag: String, _ value: String?) {
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        arguments += [flag, value]
    }

    /// Every non-empty (after trimming) entry, in order; empty entries are omitted rather than refused.
    private static func appendRepeated(_ arguments: inout [String], _ flag: String, _ values: [String]) {
        for value in values where !value.trimmingCharacters(in: .whitespaces).isEmpty {
            arguments += [flag, value]
        }
    }
}

/// A `SetupInvocation.arguments()` failure: the invocation could not be turned into a valid `yh` argument
/// vector.
public struct SetupInvocationError: Error, CustomStringConvertible, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}
