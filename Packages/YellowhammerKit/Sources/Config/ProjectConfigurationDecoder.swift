import Domain

/// Turns a parsed TOML document into a ``ProjectConfiguration``.
///
/// Within each table, unknown keys are reported first, in file order, then the known keys in a fixed order.
struct ProjectConfigurationDecoder {
    private let decoding: ConfigurationDecoding
    /// When set, the `id` must equal it.
    private let fileStem: String?

    /// When set, `change_type` and the Message Templates are not validated: a refused one is recorded
    /// in ``ProjectConfiguration/unvalidatedTemplates`` and the default stands in (`yh project remove`).
    private let lenientTemplates: Bool

    /// When set, the Project's `[board.linear] installation` must be one of these; nil skips the check.
    private let declaredLinearInstallations: Set<String>?

    init(
        file: String, fileStem: String?, declaredCLIAdapters: Set<String>? = nil,
        declaredLinearInstallations: Set<String>? = nil, lenientTemplates: Bool = false
    ) {
        decoding = ConfigurationDecoding(file: file, declaredCLIAdapters: declaredCLIAdapters)
        self.declaredLinearInstallations = declaredLinearInstallations
        self.fileStem = fileStem
        self.lenientTemplates = lenientTemplates
    }

    /// The specification-source rule runs last, so a malformed file reports its shape error first.
    func decode(_ root: TOMLTable) throws(ConfigurationError) -> ProjectConfiguration {
        try decoding.rejectUnknownKeys(
            in: root,
            path: nil,
            allowed: [
                "id", "name", "board", "spec_source", "change_type", "repos", "limits", "schedule",
                "github", "git", "routing"
            ]
        )
        var unvalidated = UnvalidatedTemplateValues()
        let id = try projectID(in: root)
        let name = try decoding.requiredString("name", in: root, path: nil)
        let board = try linearBoard(in: root)
        var configuration = ProjectConfiguration(
            id: id,
            name: name,
            linearInstallationName: board.installation,
            linearProject: board.project,
            specSource: try decoding.optionalString("spec_source", in: root, path: nil),
            repos: try repos(in: root),
            bounds: try bounds(in: root),
            schedule: try schedule(in: root),
            routingOverrides: try decoding.routingTable(in: root),
            changeType: try changeType(in: root, unvalidated: &unvalidated)
        )
        try applyGitHub(in: root, to: &configuration, unvalidated: &unvalidated)
        try applyGit(in: root, to: &configuration, unvalidated: &unvalidated)
        if lenientTemplates {
            configuration.unvalidatedTemplates = unvalidated
        }
        configuration.repoPathLines = repoPathLines(in: root)
        try requireExactlyOneSpecificationSource(in: root)
        try requireDeclaredInstallation(board)
        return configuration
    }

    // MARK: - Identity

    private func projectID(in root: TOMLTable) throws(ConfigurationError) -> ProjectID {
        let string = try decoding.requiredString("id", in: root, path: nil)
        let line = root["id"]?.line ?? root.line
        guard let id = ProjectID(rawValue: string) else {
            throw decoding.error(line: line, key: "id", .invalidProjectID(string))
        }
        if let fileStem, fileStem != string {
            throw decoding.error(line: line, key: "id", .projectIDMismatch(fileStem: fileStem))
        }
        return id
    }

    // MARK: - Repos

    private func repos(in root: TOMLTable) throws(ConfigurationError) -> [RepoDeclaration] {
        guard let value = root["repos"] else {
            throw decoding.error(line: 1, key: "repos", .missingKey)
        }
        guard case .array(let elements) = value.content else {
            let reason = ConfigurationError.Reason.typeMismatch(expected: "array of tables", found: value.typeName)
            throw decoding.error(line: value.line, key: "repos", reason)
        }
        guard !elements.isEmpty else {
            throw decoding.error(line: value.line, key: "repos", .emptyArray)
        }
        var repos: [RepoDeclaration] = []
        var firstLines: [String: Int] = [:]
        for (index, element) in elements.enumerated() {
            let path = "repos[\(index)]"
            let table = try decoding.table(element, key: path)
            let repo = try repo(table, path: path)
            if let firstLine = firstLines[repo.name] {
                throw decoding.error(line: table.line, key: "\(path).name", .duplicateRepo(firstLine: firstLine))
            }
            firstLines[repo.name] = table.line
            repos.append(repo)
        }
        return repos
    }

    private func repo(_ table: TOMLTable, path: String) throws(ConfigurationError) -> RepoDeclaration {
        try decoding.rejectUnknownKeys(
            in: table, path: path, allowed: ["name", "path", "role", "check", "protected_paths"]
        )
        let check = try decoding.requiredString("check", in: table, path: path)
        return RepoDeclaration(
            name: try decoding.requiredString("name", in: table, path: path),
            path: try decoding.requiredString("path", in: table, path: path),
            role: RepoRole(rawValue: try decoding.requiredString("role", in: table, path: path)),
            // A missing `check` was refused above: silence is never read as `none`.
            check: check == "none" ? .none : .command(check),
            protectedPaths: try protectedPaths(in: table, path: path)
        )
    }

    private func protectedPaths(in table: TOMLTable, path: String) throws(ConfigurationError) -> [String] {
        guard let value = table["protected_paths"] else { return [] }
        let key = "\(path).protected_paths"
        guard case .array(let elements) = value.content else {
            throw decoding.error(line: value.line, key: key, .typeMismatch(expected: "array", found: value.typeName))
        }
        var paths: [String] = []
        for (index, element) in elements.enumerated() {
            let elementKey = "\(key)[\(index)]"
            guard case .string(let string) = element.content else {
                let reason = ConfigurationError.Reason.typeMismatch(expected: "string", found: element.typeName)
                throw decoding.error(line: element.line, key: elementKey, reason)
            }
            guard !string.isEmpty else {
                throw decoding.error(line: element.line, key: elementKey, .emptyString)
            }
            paths.append(string)
        }
        return paths
    }

    // MARK: - Limits and schedule

    private func bounds(in root: TOMLTable) throws(ConfigurationError) -> Bounds {
        let defaults = Bounds()
        guard let value = root["limits"] else { return defaults }
        let table = try decoding.table(value, key: "limits")
        try decoding.rejectUnknownKeys(
            in: table,
            path: "limits",
            allowed: [
                "review_rounds_max", "attempts_per_work_card", "overdue_nights_max",
                "reselections_max", "consecutive_refusals_max", "failed_adoptions_max"
            ]
        )
        func bound(_ key: String, _ defaultValue: Int) throws(ConfigurationError) -> Int {
            try decoding.positiveInteger(key, in: table, path: "limits") ?? defaultValue
        }
        return Bounds(
            reviewRoundsMax: try bound("review_rounds_max", defaults.reviewRoundsMax),
            attemptsPerWorkCard: try bound("attempts_per_work_card", defaults.attemptsPerWorkCard),
            unansweredNightsMax: try bound("overdue_nights_max", defaults.unansweredNightsMax),
            reselectionsMax: try bound("reselections_max", defaults.reselectionsMax),
            consecutiveRefusalsMax: try bound("consecutive_refusals_max", defaults.consecutiveRefusalsMax),
            failedAdoptionsMax: try bound("failed_adoptions_max", defaults.failedAdoptionsMax)
        )
    }

    private func schedule(in root: TOMLTable) throws(ConfigurationError) -> Schedule {
        let defaults = Schedule()
        guard let value = root["schedule"] else { return defaults }
        let table = try decoding.table(value, key: "schedule")
        try decoding.rejectUnknownKeys(
            in: table, path: "schedule", allowed: ["night_start", "night_end", "build_every_minutes"]
        )
        return Schedule(
            nightStart: try timeOfDay("night_start", in: table) ?? defaults.nightStart,
            nightEnd: try timeOfDay("night_end", in: table) ?? defaults.nightEnd,
            buildEveryMinutes: try decoding.positiveInteger("build_every_minutes", in: table, path: "schedule")
                ?? defaults.buildEveryMinutes
        )
    }

    private func timeOfDay(_ key: String, in table: TOMLTable) throws(ConfigurationError) -> TimeOfDay? {
        guard let string = try decoding.optionalString(key, in: table, path: "schedule") else { return nil }
        guard let time = TimeOfDay(string) else {
            let line = table[key]?.line ?? table.line
            throw decoding.error(line: line, key: "schedule.\(key)", .invalidTimeOfDay(string))
        }
        return time
    }

    // MARK: - GitHub, git and templates

    /// `[github]` in a Project file: an optional `credential` override and the `pull_request_title`
    /// template. Either may stand alone, so a `[github]` with only a title means no credential override.
    /// (The machine file's `[github]` stays credential-only: ``ConfigurationDecoding/credential(in:table:)``.)
    private func applyGitHub(
        in root: TOMLTable, to configuration: inout ProjectConfiguration, unvalidated: inout UnvalidatedTemplateValues
    ) throws(ConfigurationError) {
        guard let value = root["github"] else { return }
        let table = try decoding.table(value, key: "github")
        try decoding.rejectUnknownKeys(in: table, path: "github", allowed: ["credential", "pull_request_title"])
        if let string = try decoding.optionalString("credential", in: table, path: "github") {
            guard let reference = CredentialReference(string) else {
                let line = table["credential"]?.line ?? table.line
                throw decoding.error(line: line, key: "github.credential", .emptyString)
            }
            configuration.gitHubCredential = reference
        }
        configuration.pullRequestTitle = try template(
            .pullRequestTitle, in: table, path: "github", unvalidated: &unvalidated
        )
    }

    private func applyGit(
        in root: TOMLTable, to configuration: inout ProjectConfiguration, unvalidated: inout UnvalidatedTemplateValues
    ) throws(ConfigurationError) {
        guard let value = root["git"] else { return }
        let table = try decoding.table(value, key: "git")
        try decoding.rejectUnknownKeys(in: table, path: "git", allowed: ["commit_message", "wip_commit_message"])
        configuration.commitMessage = try template(.commitMessage, in: table, path: "git", unvalidated: &unvalidated)
        configuration.wipCommitMessage = try template(
            .wipCommitMessage, in: table, path: "git", unvalidated: &unvalidated
        )
    }

    /// The template at `kind.key`, or its default when absent. When lenient, a refused one is recorded
    /// and replaced by the default.
    private func template(
        _ kind: MessageTemplate.Kind, in table: TOMLTable, path: String, unvalidated: inout UnvalidatedTemplateValues
    ) throws(ConfigurationError) -> MessageTemplate {
        let fallback = MessageTemplate.default(kind)
        guard lenientTemplates else {
            return try decoding.messageTemplate(kind, in: table, path: path) ?? fallback
        }
        if kind == .wipCommitMessage, case .string(let raw)? = table[kind.key]?.content {
            unvalidated.wipCommitMessage = raw
        }
        do throws(ConfigurationError) {
            return try decoding.messageTemplate(kind, in: table, path: path) ?? fallback
        } catch {
            unvalidated.refusals.append(error)
            return fallback
        }
    }

    /// The top-level `change_type`, or `feat` when absent. When lenient, a refused one is recorded and
    /// replaced by `feat`.
    private func changeType(
        in root: TOMLTable, unvalidated: inout UnvalidatedTemplateValues
    ) throws(ConfigurationError) -> ChangeType {
        if lenientTemplates, case .string(let raw)? = root["change_type"]?.content {
            unvalidated.changeType = raw
        }
        do throws(ConfigurationError) {
            guard let string = try decoding.optionalString("change_type", in: root, path: nil) else { return .feat }
            guard let changeType = ChangeType(string) else {
                throw decoding.error(line: root["change_type"]?.line ?? 1, key: "change_type", .emptyString)
            }
            return changeType
        } catch {
            guard lenientTemplates else { throw error }
            unvalidated.refusals.append(error)
            return .feat
        }
    }
}

extension ProjectConfigurationDecoder {
    // MARK: - Specification source

    /// Exactly one across both kinds — a `spec_source` path or one Repo of Repo Role `spec` — never
    /// two of either, never one of each, and never none (glossary → Spec Source; feature-authoring
    /// business rules). Sources are counted in file order and the second one found is refused.
    private func requireExactlyOneSpecificationSource(in root: TOMLTable) throws(ConfigurationError) {
        var sources: [(key: String, line: Int)] = []
        if let specSource = root["spec_source"] {
            sources.append((key: "spec_source", line: specSource.line))
        }
        if case .array(let elements)? = root["repos"]?.content {
            for (index, element) in elements.enumerated() {
                guard case .table(let table) = element.content,
                      case .string("spec")? = table["role"]?.content
                else { continue }
                sources.append((key: "repos[\(index)].role", line: table["role"]?.line ?? table.line))
            }
        }
        sources.sort { $0.line < $1.line }
        guard let first = sources.first else {
            throw decoding.error(line: 1, key: nil, .noSpecificationSource)
        }
        if sources.count > 1 {
            let second = sources[1]
            throw decoding.error(line: second.line, key: second.key, .secondSpecificationSource(firstLine: first.line))
        }
    }

    /// Run after ``repos(in:)`` succeeded, so every element is a table with a `path`.
    private func repoPathLines(in root: TOMLTable) -> [Int] {
        guard case .array(let elements)? = root["repos"]?.content else { return [] }
        return elements.map { element in
            guard case .table(let table) = element.content else { return element.line }
            return table["path"]?.line ?? table.line
        }
    }

    // MARK: - Board

    fileprivate struct LinearBoard {
        let installation: String
        let project: String
        let installationLine: Int
    }

    /// `[board.linear]`: the App Installation this Project selects by name and the Linear project it
    /// projects onto. Exactly one vendor table is accepted, so a second `[board.<vendor>]`, or a vendor
    /// other than `linear`, is an unknown key.
    private func linearBoard(in root: TOMLTable) throws(ConfigurationError) -> LinearBoard {
        guard let boardValue = root["board"] else {
            throw decoding.error(line: 1, key: "board", .missingTable)
        }
        let board = try decoding.table(boardValue, key: "board")
        try decoding.rejectUnknownKeys(in: board, path: "board", allowed: ["linear"])
        guard let linearValue = board["linear"] else {
            throw decoding.error(line: board.line, key: "board.linear", .missingTable)
        }
        let linear = try decoding.table(linearValue, key: "board.linear")
        try decoding.rejectUnknownKeys(in: linear, path: "board.linear", allowed: ["installation", "project"])
        return LinearBoard(
            installation: try decoding.requiredString("installation", in: linear, path: "board.linear"),
            project: try decoding.requiredString("project", in: linear, path: "board.linear"),
            installationLine: linear["installation"]?.line ?? linear.line
        )
    }

    /// Refuses an `installation` the machine file's registry does not declare, when
    /// ``declaredLinearInstallations`` is set. Runs after the shape decoded, so a shape error is
    /// always reported first.
    private func requireDeclaredInstallation(_ board: LinearBoard) throws(ConfigurationError) {
        guard let declaredLinearInstallations, !declaredLinearInstallations.contains(board.installation) else {
            return
        }
        throw decoding.error(
            line: board.installationLine, key: "board.linear.installation",
            .undeclaredLinearInstallation(board.installation)
        )
    }
}
