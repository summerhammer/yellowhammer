import Domain

/// Turns a parsed TOML document into a ``MachineConfiguration``.
///
/// Within each table, unknown keys are reported first, in file order, then the known keys in a fixed order.
struct MachineConfigurationDecoder {
    private static let defaultEffort = "medium"

    let file: String

    func decode(_ root: TOMLTable) throws(ConfigurationError) -> MachineConfiguration {
        try rejectUnknownKeys(in: root, path: nil, allowed: ["linear", "github", "cli", "routing"])
        return MachineConfiguration(
            linearCredential: try credential(in: root, table: "linear"),
            gitHubCredential: try credential(in: root, table: "github"),
            cliAdapters: try cliAdapters(in: root),
            routingTable: try routingTable(in: root)
        )
    }

    // MARK: - Sections

    private func credential(in root: TOMLTable, table name: String) throws(ConfigurationError) -> CredentialReference {
        guard let value = root[name] else {
            throw error(line: 1, key: name, .missingTable)
        }
        let table = try table(value, key: name)
        try rejectUnknownKeys(in: table, path: name, allowed: ["credential"])
        let key = TOMLKey.path(name, "credential")
        let string = try requiredString("credential", in: table, path: name)
        guard let reference = CredentialReference(string) else {
            throw error(line: table["credential"]?.line ?? table.line, key: key, .emptyString)
        }
        return reference
    }

    private func cliAdapters(in root: TOMLTable) throws(ConfigurationError) -> [CLIAdapterDeclaration] {
        guard let value = root["cli"] else { return [] }
        let adapters = try table(value, key: "cli")
        var declarations: [CLIAdapterDeclaration] = []
        for entry in adapters.entries {
            let path = TOMLKey.path("cli", entry.key)
            let declaration = try table(entry.value, key: path)
            guard !entry.key.isEmpty else {
                throw error(line: entry.value.line, key: path, .emptyString)
            }
            try rejectUnknownKeys(in: declaration, path: path, allowed: ["executable"])
            let executable = try optionalString("executable", in: declaration, path: path)
            declarations.append(CLIAdapterDeclaration(name: entry.key, executable: executable))
        }
        return declarations
    }

    private func routingTable(in root: TOMLTable) throws(ConfigurationError) -> [RoutingEntry] {
        guard let value = root["routing"] else { return [] }
        guard case .array(let elements) = value.content else {
            let reason = ConfigurationError.Reason.typeMismatch(expected: "array of tables", found: value.typeName)
            throw error(line: value.line, key: "routing", reason)
        }
        var entries: [RoutingEntry] = []
        var firstLines: [RoutingKey: Int] = [:]
        for (index, element) in elements.enumerated() {
            let path = "routing[\(index)]"
            guard case .table(let table) = element.content else {
                throw error(line: element.line, key: path, .typeMismatch(expected: "table", found: element.typeName))
            }
            let entry = try routingEntry(table, path: path)
            let key = RoutingKey(kind: entry.kind, repoRole: entry.repoRole)
            if let firstLine = firstLines[key] {
                throw error(line: table.line, key: path, .duplicateRoutingEntry(firstLine: firstLine))
            }
            firstLines[key] = table.line
            entries.append(entry)
        }
        return entries
    }

    private struct RoutingKey: Hashable {
        let kind: Kind
        let repoRole: RepoRoleMatch
    }

    // MARK: - Routing Entries

    private func routingEntry(_ table: TOMLTable, path: String) throws(ConfigurationError) -> RoutingEntry {
        try rejectUnknownKeys(in: table, path: path, allowed: ["kind", "repo_role", "route", "fallbacks"])
        var kind = Kind.any
        if let string = try optionalString("kind", in: table, path: path, allowEmpty: true) {
            guard let parsed = Kind(string) else {
                throw error(line: table["kind"]?.line ?? table.line, key: "\(path).kind", .invalidKind(string))
            }
            kind = parsed
        }
        var repoRole = RepoRoleMatch.any
        if let string = try optionalString("repo_role", in: table, path: path), string != "*" {
            repoRole = .role(RepoRole(rawValue: string))
        }
        guard let routeValue = table["route"] else {
            throw error(line: table.line, key: "\(path).route", .missingKey)
        }
        let route = try route(routeValue, path: "\(path).route", defaultEffort: Self.defaultEffort)
        return RoutingEntry(
            kind: kind,
            repoRole: repoRole,
            route: route,
            fallbacks: try fallbacks(in: table, path: path, defaultEffort: route.effort)
        )
    }

    private func fallbacks(
        in table: TOMLTable, path: String, defaultEffort: String
    ) throws(ConfigurationError) -> [Route] {
        guard let value = table["fallbacks"] else { return [] }
        let key = "\(path).fallbacks"
        guard case .array(let elements) = value.content else {
            throw error(line: value.line, key: key, .typeMismatch(expected: "array", found: value.typeName))
        }
        var routes: [Route] = []
        for (index, element) in elements.enumerated() {
            routes.append(try route(element, path: "\(key)[\(index)]", defaultEffort: defaultEffort))
        }
        return routes
    }

    /// A `cli/model` or `cli/model/effort` string, or a table with `cli`, `model` and optional `effort`.
    private func route(_ value: TOMLValue, path: String, defaultEffort: String) throws(ConfigurationError) -> Route {
        switch value.content {
        case .string(let string):
            let parts = string.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard (2...3).contains(parts.count),
                  let route = Route(cli: parts[0], model: parts[1], effort: parts.count == 3 ? parts[2] : defaultEffort)
            else {
                throw error(line: value.line, key: path, .invalidRoute(string))
            }
            return route
        case .table(let table):
            try rejectUnknownKeys(in: table, path: path, allowed: ["cli", "model", "effort"])
            let cli = try requiredString("cli", in: table, path: path)
            let model = try requiredString("model", in: table, path: path)
            let effort = try optionalString("effort", in: table, path: path) ?? defaultEffort
            guard let route = Route(cli: cli, model: model, effort: effort) else {
                throw error(line: table.line, key: path, .emptyString)
            }
            return route
        default:
            throw error(line: value.line, key: path, .typeMismatch(expected: "string or table", found: value.typeName))
        }
    }

    // MARK: - Values

    private func error(line: Int, key: String?, _ reason: ConfigurationError.Reason) -> ConfigurationError {
        ConfigurationError(file: file, line: line, key: key, reason: reason)
    }

    private func rejectUnknownKeys(
        in table: TOMLTable, path: String?, allowed: Set<String>
    ) throws(ConfigurationError) {
        if let unknown = table.entries.first(where: { !allowed.contains($0.key) }) {
            throw error(line: unknown.value.line, key: TOMLKey.path(path, unknown.key), .unknownKey)
        }
    }

    private func table(_ value: TOMLValue, key: String) throws(ConfigurationError) -> TOMLTable {
        guard case .table(let table) = value.content else {
            throw error(line: value.line, key: key, .typeMismatch(expected: "table", found: value.typeName))
        }
        return table
    }

    /// A missing key is reported on its table's line.
    private func requiredString(_ key: String, in table: TOMLTable, path: String) throws(ConfigurationError) -> String {
        guard let string = try optionalString(key, in: table, path: path) else {
            throw error(line: table.line, key: TOMLKey.path(path, key), .missingKey)
        }
        return string
    }

    private func optionalString(
        _ key: String, in table: TOMLTable, path: String, allowEmpty: Bool = false
    ) throws(ConfigurationError) -> String? {
        guard let value = table[key] else { return nil }
        let keyPath = TOMLKey.path(path, key)
        guard case .string(let string) = value.content else {
            throw error(line: value.line, key: keyPath, .typeMismatch(expected: "string", found: value.typeName))
        }
        guard allowEmpty || !string.isEmpty else {
            throw error(line: value.line, key: keyPath, .emptyString)
        }
        return string
    }
}
