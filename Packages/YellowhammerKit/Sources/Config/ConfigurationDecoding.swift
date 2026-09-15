import Domain

/// The value readers and Routing Table decoding shared by the machine-wide and per-Project decoders.
///
/// Every error carries the file, the line and a dotted, indexed key.
struct ConfigurationDecoding {
    private static let defaultEffort = "medium"

    let file: String
    /// When set, every route must name one of these CLI Adapters; nil skips the check.
    var declaredCLIAdapters: Set<String>?

    init(file: String, declaredCLIAdapters: Set<String>? = nil) {
        self.file = file
        self.declaredCLIAdapters = declaredCLIAdapters
    }

    func error(line: Int, key: String?, _ reason: ConfigurationError.Reason) -> ConfigurationError {
        ConfigurationError(file: file, line: line, key: key, reason: reason)
    }

    func rejectUnknownKeys(
        in table: TOMLTable, path: String?, allowed: Set<String>
    ) throws(ConfigurationError) {
        if let unknown = table.entries.first(where: { !allowed.contains($0.key) }) {
            throw error(line: unknown.value.line, key: TOMLKey.path(path, unknown.key), .unknownKey)
        }
    }

    func table(_ value: TOMLValue, key: String) throws(ConfigurationError) -> TOMLTable {
        guard case .table(let table) = value.content else {
            throw error(line: value.line, key: key, .typeMismatch(expected: "table", found: value.typeName))
        }
        return table
    }

    /// A `[<table>]` holding one non-empty `credential`.
    func credential(in root: TOMLTable, table name: String) throws(ConfigurationError) -> CredentialReference {
        guard let value = root[name] else {
            throw error(line: 1, key: name, .missingTable)
        }
        let table = try table(value, key: name)
        try rejectUnknownKeys(in: table, path: name, allowed: ["credential"])
        let string = try requiredString("credential", in: table, path: name)
        guard let reference = CredentialReference(string) else {
            let line = table["credential"]?.line ?? table.line
            throw error(line: line, key: TOMLKey.path(name, "credential"), .emptyString)
        }
        return reference
    }

    /// A missing key is reported on its table's line.
    func requiredString(_ key: String, in table: TOMLTable, path: String?) throws(ConfigurationError) -> String {
        guard let string = try optionalString(key, in: table, path: path) else {
            throw error(line: table.line, key: TOMLKey.path(path, key), .missingKey)
        }
        return string
    }

    func optionalString(
        _ key: String, in table: TOMLTable, path: String?, allowEmpty: Bool = false
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

    /// An integer of at least 1, or nil when the key is absent.
    func positiveInteger(_ key: String, in table: TOMLTable, path: String?) throws(ConfigurationError) -> Int? {
        guard let value = table[key] else { return nil }
        let keyPath = TOMLKey.path(path, key)
        guard case .integer(let integer) = value.content else {
            throw error(line: value.line, key: keyPath, .typeMismatch(expected: "integer", found: value.typeName))
        }
        guard integer >= 1, let result = Int(exactly: integer) else {
            throw error(line: value.line, key: keyPath, .notPositive(integer))
        }
        return result
    }

    func routingTable(in root: TOMLTable) throws(ConfigurationError) -> [RoutingEntry] {
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
        try requireDeclaredAdapters(for: entries, elements: elements)
        return entries
    }

    private struct RoutingKey: Hashable {
        let kind: Kind
        let repoRole: RepoRoleMatch
    }

    func routingEntry(_ table: TOMLTable, path: String) throws(ConfigurationError) -> RoutingEntry {
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

    /// Refuses a route whose CLI has no adapter declaration when ``declaredCLIAdapters`` is set
    /// (routing/add-an-agent-cli): a CLI in the Routing Table without an adapter fails at load, not
    /// at 02:00. Runs after the whole table decoded, so a shape error is always reported first.
    private func requireDeclaredAdapters(
        for entries: [RoutingEntry], elements: [TOMLValue]
    ) throws(ConfigurationError) {
        guard let declaredCLIAdapters else { return }
        for (index, entry) in entries.enumerated() {
            guard case .table(let table) = elements[index].content else { continue }
            let path = "routing[\(index)]"
            if !declaredCLIAdapters.contains(entry.route.cli) {
                let line = table["route"]?.line ?? table.line
                throw error(line: line, key: "\(path).route", .undeclaredCLIAdapter(entry.route.cli))
            }
            guard case .array(let fallbacks)? = table["fallbacks"]?.content else { continue }
            for (fallbackIndex, fallback) in entry.fallbacks.enumerated()
            where !declaredCLIAdapters.contains(fallback.cli) {
                let key = "\(path).fallbacks[\(fallbackIndex)]"
                throw error(line: fallbacks[fallbackIndex].line, key: key, .undeclaredCLIAdapter(fallback.cli))
            }
        }
    }

    /// A `cli/model` or `cli/model/effort` string, or a table with `cli`, `model` and optional `effort`.
    func route(_ value: TOMLValue, path: String, defaultEffort: String) throws(ConfigurationError) -> Route {
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
}
