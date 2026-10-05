import Domain
import Foundation

/// One Project's configuration file: its Linear project, Repos, specification source, Bounds, schedule,
/// optional GitHub credential and Routing Table overrides.
///
/// Decoding also enforces that the Project has exactly one specification source, counted across both
/// kinds: a `spec_source` path, or one Repo of Repo Role `spec`. Rules that span Projects, or that
/// need the machine-wide file, are checked by ``Configuration``.
public struct ProjectConfiguration: Sendable {
    public var id: ProjectID
    public var name: String
    /// The local name of the machine file's App Installation this Project selects
    /// (`[board.linear] installation`); see ``MachineConfiguration/linearInstallation(for:)``.
    public var linearInstallationName: String
    /// Linear's project this Project projects onto (`[board.linear] project`), as an opaque reference.
    public var linearProject: String
    /// The path of the Spec Source, as written. Absent when the specification source is a Repo of Repo Role `spec`.
    public var specSource: String?
    /// In file order; never empty.
    public var repos: [RepoDeclaration]
    public var bounds: Bounds
    public var schedule: Schedule
    /// Overrides the machine default GitHub credential when present.
    public var gitHubCredential: CredentialReference?
    /// This Project's Routing Table overrides, in file order, not yet merged with the base table.
    public var routingOverrides: [RoutingEntry]
    /// The Project's Change Type, `feat` when the file sets none.
    public var changeType: ChangeType
    /// `[github] pull_request_title`, or its built-in default.
    public var pullRequestTitle: MessageTemplate
    /// `[git] commit_message`, or its built-in default.
    public var commitMessage: MessageTemplate
    /// `[git] wip_commit_message`, or its built-in default.
    public var wipCommitMessage: MessageTemplate
    /// Set only by a lenient load (``Configuration/loadLeniently(directory:)``, used by `yh project remove`):
    /// what the template keys held, as written, and why each was refused. The typed template properties
    /// above then hold their defaults for every refused key. Not part of equality.
    public internal(set) var unvalidatedTemplates: UnvalidatedTemplateValues?
    /// The line of each Repo's `path` key, parallel to `repos`, so that a cross-Project error can
    /// point at it. Empty for a value not decoded from a file. Not part of equality.
    var repoPathLines: [Int] = []

    public init(
        id: ProjectID,
        name: String,
        linearInstallationName: String,
        linearProject: String,
        specSource: String? = nil,
        repos: [RepoDeclaration],
        bounds: Bounds = Bounds(),
        schedule: Schedule = Schedule(),
        gitHubCredential: CredentialReference? = nil,
        routingOverrides: [RoutingEntry] = [],
        changeType: ChangeType = .feat,
        pullRequestTitle: MessageTemplate = .default(.pullRequestTitle),
        commitMessage: MessageTemplate = .default(.commitMessage),
        wipCommitMessage: MessageTemplate = .default(.wipCommitMessage)
    ) {
        self.id = id
        self.name = name
        self.linearInstallationName = linearInstallationName
        self.linearProject = linearProject
        self.specSource = specSource
        self.repos = repos
        self.bounds = bounds
        self.schedule = schedule
        self.gitHubCredential = gitHubCredential
        self.routingOverrides = routingOverrides
        self.changeType = changeType
        self.pullRequestTitle = pullRequestTitle
        self.commitMessage = commitMessage
        self.wipCommitMessage = wipCommitMessage
    }

    /// The Project's repositories expressed in Domain vocabulary, with home-directory tildes expanded
    /// for filesystem and process use. ``repos`` and ``specSource`` retain the paths as written.
    public var projectRepositories: ProjectRepositories {
        let workingRepos = repos.map {
            Repo(
                name: $0.name, path: ($0.path as NSString).expandingTildeInPath,
                role: $0.role, protectedPaths: $0.protectedPaths
            )
        }
        let spec = specSource.map { SpecSource(path: ($0 as NSString).expandingTildeInPath) }
        return ProjectRepositories(workingRepos: workingRepos, specSource: spec)
    }

    /// Alias for ``projectRepositories``.
    public var repositories: ProjectRepositories {
        projectRepositories
    }
}

extension ProjectConfiguration: Equatable {
    /// Compares every property but ``repoPathLines`` and ``unvalidatedTemplates``, which are source bookkeeping, not configuration.
    public static func == (lhs: ProjectConfiguration, rhs: ProjectConfiguration) -> Bool {
        lhs.id == rhs.id
            && lhs.name == rhs.name
            && lhs.linearInstallationName == rhs.linearInstallationName
            && lhs.linearProject == rhs.linearProject
            && lhs.specSource == rhs.specSource
            && lhs.repos == rhs.repos
            && lhs.bounds == rhs.bounds
            && lhs.schedule == rhs.schedule
            && lhs.gitHubCredential == rhs.gitHubCredential
            && lhs.routingOverrides == rhs.routingOverrides
            && lhs.changeType == rhs.changeType
            && lhs.pullRequestTitle == rhs.pullRequestTitle
            && lhs.commitMessage == rhs.commitMessage
            && lhs.wipCommitMessage == rhs.wipCommitMessage
    }
}

extension ProjectConfiguration {
    /// `~/.config/yellowhammer/projects/<id>.toml` under the given home directory.
    public static func defaultFileURL(homeDirectory: URL, id: ProjectID) -> URL {
        homeDirectory.appending(
            components: ".config", "yellowhammer", "projects", "\(id.rawValue).toml",
            directoryHint: .notDirectory
        )
    }

    /// Also refuses a file whose name, less its extension, is not its `id`.
    ///
    /// When `declaredCLIAdapters` is given, every route in the Routing Table overrides must name one
    /// of them; when `declaredLinearInstallations` is given, the Project's installation must be one of
    /// them. nil skips either check, which needs the machine-wide file.
    public static func load(
        contentsOf url: URL, declaredCLIAdapters: Set<String>? = nil,
        declaredLinearInstallations: Set<String>? = nil
    ) throws(ConfigurationError) -> ProjectConfiguration {
        try load(
            contentsOf: url, declaredCLIAdapters: declaredCLIAdapters,
            declaredLinearInstallations: declaredLinearInstallations, lenientTemplates: false
        )
    }

    static func load(
        contentsOf url: URL, declaredCLIAdapters: Set<String>?, declaredLinearInstallations: Set<String>?,
        lenientTemplates: Bool
    ) throws(ConfigurationError) -> ProjectConfiguration {
        let file = url.path(percentEncoded: false)
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw ConfigurationError(file: file, line: 1, key: nil, reason: .unreadable(error.localizedDescription))
        }
        return try parse(
            text,
            file: file,
            fileStem: url.deletingPathExtension().lastPathComponent,
            declaredCLIAdapters: declaredCLIAdapters,
            declaredLinearInstallations: declaredLinearInstallations,
            lenientTemplates: lenientTemplates
        )
    }

    public static func parse(
        _ text: String, file: String, declaredCLIAdapters: Set<String>? = nil,
        declaredLinearInstallations: Set<String>? = nil
    ) throws(ConfigurationError) -> ProjectConfiguration {
        try parse(
            text, file: file, fileStem: nil, declaredCLIAdapters: declaredCLIAdapters,
            declaredLinearInstallations: declaredLinearInstallations, lenientTemplates: false
        )
    }

    // swiftlint:disable function_parameter_count
    /// Also used by ``Configuration/load(directory:reading:as:)`` to parse a Project file's substituted
    /// text against its filename's stem, without re-reading it from disk.
    static func parse(
        _ text: String, file: String, fileStem: String?, declaredCLIAdapters: Set<String>?,
        declaredLinearInstallations: Set<String>?, lenientTemplates: Bool
    ) throws(ConfigurationError) -> ProjectConfiguration {
        let root = try TOMLParser.parse(text, file: file)
        let decoder = ProjectConfigurationDecoder(
            file: file, fileStem: fileStem, declaredCLIAdapters: declaredCLIAdapters,
            declaredLinearInstallations: declaredLinearInstallations, lenientTemplates: lenientTemplates
        )
        return try decoder.decode(root)
    }
    // swiftlint:enable function_parameter_count
}

/// What a lenient load found under the template keys: the raw strings as written, and each refusal a
/// normal load would have thrown. See ``ProjectConfiguration/unvalidatedTemplates``.
public struct UnvalidatedTemplateValues: Equatable, Sendable {
    /// `change_type` as written; nil when absent or not a string.
    public var changeType: String?
    /// `[git] wip_commit_message` as written; nil when absent or not a string. The removal's safety WIP
    /// Commit renders it when it validates, and the built-in default when it does not.
    public var wipCommitMessage: String?
    /// One per refused key, in the order the decoder reads them.
    public var refusals: [ConfigurationError] = []

    public init(changeType: String? = nil, wipCommitMessage: String? = nil, refusals: [ConfigurationError] = []) {
        self.changeType = changeType
        self.wipCommitMessage = wipCommitMessage
        self.refusals = refusals
    }
}

/// A repository declared in a Project's `[[repos]]`.
public struct RepoDeclaration: Equatable, Sendable {
    public var name: String
    /// As written.
    public var path: String
    public var role: RepoRole
    /// The repository's `check` key, required. Accepted cost (risk R6): a flaky Check blocks a Card that
    /// nothing was wrong with, and with a round budget of two it does so quickly.
    public var check: Check
    public var protectedPaths: [String]

    public init(name: String, path: String, role: RepoRole, check: Check, protectedPaths: [String] = []) {
        self.name = name
        self.path = path
        self.role = role
        self.check = check
        self.protectedPaths = protectedPaths
    }
}

/// A Project's six Bounds, from `[limits]`. Each is an integer of at least 1 and fires when its count exceeds it.
public struct Bounds: Equatable, Sendable {
    public var reviewRoundsMax: Int
    public var attemptsPerCard: Int
    public var unansweredNightsMax: Int
    public var reselectionsMax: Int
    public var consecutiveRefusalsMax: Int
    public var failedAdoptionsMax: Int

    /// The defaults are the spec's: bounds/overview and the Decision Gates Ruling, G-13 and G-16.
    public init(
        reviewRoundsMax: Int = 2,
        attemptsPerCard: Int = 3,
        unansweredNightsMax: Int = 3,
        reselectionsMax: Int = 2,
        consecutiveRefusalsMax: Int = 3,
        failedAdoptionsMax: Int = 2
    ) {
        self.reviewRoundsMax = reviewRoundsMax
        self.attemptsPerCard = attemptsPerCard
        self.unansweredNightsMax = unansweredNightsMax
        self.reselectionsMax = reselectionsMax
        self.consecutiveRefusalsMax = consecutiveRefusalsMax
        self.failedAdoptionsMax = failedAdoptionsMax
    }
}

/// A Project's `[schedule]`, from which setup generates its LaunchAgents.
public struct Schedule: Equatable, Sendable {
    public var nightStart: TimeOfDay
    public var nightEnd: TimeOfDay
    public var buildEveryMinutes: Int

    /// The defaults are the spec's: Decision Gates Ruling, G-7.
    public init(
        nightStart: TimeOfDay = TimeOfDay(uncheckedHour: 22, minute: 0),
        nightEnd: TimeOfDay = TimeOfDay(uncheckedHour: 6, minute: 0),
        buildEveryMinutes: Int = 15
    ) {
        self.nightStart = nightStart
        self.nightEnd = nightEnd
        self.buildEveryMinutes = buildEveryMinutes
    }
}

/// A wall-clock time written `HH:MM`.
public struct TimeOfDay: Hashable, Sendable {
    public let hour: Int
    public let minute: Int

    /// Fails unless `hour` is 0–23 and `minute` is 0–59.
    public init?(hour: Int, minute: Int) {
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        self.init(uncheckedHour: hour, minute: minute)
    }

    /// Accepts exactly two ASCII digits, a colon and two ASCII digits, such as `06:00`.
    public init?(_ string: String) {
        let scalars = Array(string.unicodeScalars)
        guard scalars.count == 5, scalars[2] == ":" else { return nil }
        let digits = [scalars[0], scalars[1], scalars[3], scalars[4]].compactMap { scalar -> Int? in
            ("0"..."9").contains(scalar) ? Int(scalar.value - 48) : nil
        }
        guard digits.count == 4 else { return nil }
        self.init(hour: digits[0] * 10 + digits[1], minute: digits[2] * 10 + digits[3])
    }

    /// For constants known to be in range; public default arguments may only use `@usableFromInline` code.
    @usableFromInline
    init(uncheckedHour hour: Int, minute: Int) {
        self.hour = hour
        self.minute = minute
    }
}

extension TimeOfDay: CustomStringConvertible {
    public var description: String {
        String(format: "%02d:%02d", hour, minute)
    }
}
