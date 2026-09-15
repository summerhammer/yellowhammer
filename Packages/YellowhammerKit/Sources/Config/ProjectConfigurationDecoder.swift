import Domain

/// Turns a parsed TOML document into a ``ProjectConfiguration``.
///
/// Within each table, unknown keys are reported first, in file order, then the known keys in a fixed order.
struct ProjectConfigurationDecoder {
    private let decoding: ConfigurationDecoding
    /// When set, the `id` must equal it.
    private let fileStem: String?

    init(file: String, fileStem: String?, declaredCLIAdapters: Set<String>? = nil) {
        decoding = ConfigurationDecoding(file: file, declaredCLIAdapters: declaredCLIAdapters)
        self.fileStem = fileStem
    }

    /// The specification-source rule runs last, so a malformed file reports its shape error first.
    func decode(_ root: TOMLTable) throws(ConfigurationError) -> ProjectConfiguration {
        try decoding.rejectUnknownKeys(
            in: root,
            path: nil,
            allowed: ["id", "name", "linear_project", "spec_source", "repos", "limits", "schedule", "github", "routing"]
        )
        var configuration = ProjectConfiguration(
            id: try projectID(in: root),
            name: try decoding.requiredString("name", in: root, path: nil),
            linearProject: try decoding.requiredString("linear_project", in: root, path: nil),
            specSource: try decoding.optionalString("spec_source", in: root, path: nil),
            repos: try repos(in: root),
            bounds: try bounds(in: root),
            schedule: try schedule(in: root),
            gitHubCredential: try gitHubCredential(in: root),
            routingOverrides: try decoding.routingTable(in: root)
        )
        configuration.repoPathLines = repoPathLines(in: root)
        try requireExactlyOneSpecificationSource(in: root)
        return configuration
    }

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
                "review_rounds_max", "attempts_per_card", "unanswered_nights_max",
                "reselections_max", "consecutive_refusals_max", "failed_adoptions_max"
            ]
        )
        func bound(_ key: String, _ defaultValue: Int) throws(ConfigurationError) -> Int {
            try decoding.positiveInteger(key, in: table, path: "limits") ?? defaultValue
        }
        return Bounds(
            reviewRoundsMax: try bound("review_rounds_max", defaults.reviewRoundsMax),
            attemptsPerCard: try bound("attempts_per_card", defaults.attemptsPerCard),
            unansweredNightsMax: try bound("unanswered_nights_max", defaults.unansweredNightsMax),
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

    // MARK: - GitHub

    private func gitHubCredential(in root: TOMLTable) throws(ConfigurationError) -> CredentialReference? {
        guard root["github"] != nil else { return nil }
        return try decoding.credential(in: root, table: "github")
    }
}
