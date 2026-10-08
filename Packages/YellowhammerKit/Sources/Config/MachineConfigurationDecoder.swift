import Domain

/// Turns a parsed TOML document into a ``MachineConfiguration``.
///
/// Within each table, unknown keys are reported first, in file order, then the known keys in a fixed order.
struct MachineConfigurationDecoder {
    private let decoding: ConfigurationDecoding

    init(file: String) {
        decoding = ConfigurationDecoding(file: file)
    }

    /// The base Routing Table is checked against this file's own `[cli]` declarations: every route
    /// must name a declared CLI Adapter.
    func decode(_ root: TOMLTable) throws(ConfigurationError) -> MachineConfiguration {
        try decoding.rejectUnknownKeys(in: root, path: nil, allowed: ["board", "code_hosting", "cli", "routing"])
        let linearInstallations = try linearInstallations(in: root)
        let codeHostingConnections = try codeHostingConnections(in: root)
        let cliAdapters = try cliAdapters(in: root)
        var routingDecoding = decoding
        routingDecoding.declaredCLIAdapters = Set(cliAdapters.map(\.name))
        return MachineConfiguration(
            linearInstallations: linearInstallations,
            codeHostingConnections: codeHostingConnections,
            cliAdapters: cliAdapters,
            routingTable: try routingDecoding.routingTable(in: root)
        )
    }

    // MARK: - Sections

    /// `[board.linear.connections.<name>]`, zero or more: the registry of Board Connections. Each
    /// carries a required `credential`, `workspace` and `yellowhammer_identity` and an optional Operator identity
    /// (`operator`). An absent or empty `operator` decodes to nil — never a load-time validation failure
    /// (Operator Identity Ruling — 2026-09-23). Two entries may not share a `workspace`.
    ///
    /// `[board]`, `[board.linear]` and `[board.linear.connections]` may each be absent or empty.
    private func linearInstallations(in root: TOMLTable) throws(ConfigurationError) -> [LinearInstallation] {
        guard let boardValue = root["board"] else { return [] }
        let board = try decoding.table(boardValue, key: "board")
        try decoding.rejectUnknownKeys(in: board, path: "board", allowed: ["linear"])
        guard let linearValue = board["linear"] else { return [] }
        let linear = try decoding.table(linearValue, key: "board.linear")
        try decoding.rejectUnknownKeys(in: linear, path: "board.linear", allowed: ["connections"])
        guard let registryValue = linear["connections"] else { return [] }
        let registry = try decoding.table(registryValue, key: "board.linear.connections")

        var installations: [LinearInstallation] = []
        var firstWorkspaces: [String: (installation: String, line: Int)] = [:]
        for entry in registry.entries {
            let path = TOMLKey.path("board.linear.connections", entry.key)
            let table = try decoding.table(entry.value, key: path)
            guard !entry.key.isEmpty else {
                throw decoding.error(line: entry.value.line, key: path, .emptyString)
            }
            let installation = try linearInstallation(named: entry.key, in: table, path: path)
            let workspaceLine = table["workspace"]?.line ?? table.line
            if let first = firstWorkspaces[installation.workspace.rawValue] {
                throw decoding.error(
                    line: workspaceLine, key: TOMLKey.path(path, "workspace"),
                    .duplicateLinearWorkspace(firstInstallation: first.installation, firstLine: first.line)
                )
            }
            firstWorkspaces[installation.workspace.rawValue] = (entry.key, workspaceLine)
            installations.append(installation)
        }
        return installations
    }

    private func linearInstallation(
        named name: String, in table: TOMLTable, path: String
    ) throws(ConfigurationError) -> LinearInstallation {
        try decoding.rejectUnknownKeys(
            in: table, path: path, allowed: ["credential", "workspace", "yellowhammer_identity", "operator"]
        )
        let credentialString = try decoding.requiredString("credential", in: table, path: path)
        guard let credential = CredentialReference(credentialString) else {
            let line = table["credential"]?.line ?? table.line
            throw decoding.error(line: line, key: TOMLKey.path(path, "credential"), .emptyString)
        }
        let workspace = try decoding.requiredString("workspace", in: table, path: path)
        let appUser = try decoding.requiredString("yellowhammer_identity", in: table, path: path)
        let operatorString = try decoding.optionalString("operator", in: table, path: path, allowEmpty: true)
        return LinearInstallation(
            name: name,
            credential: credential,
            workspace: BoardObjectID(rawValue: workspace),
            appUser: BoardObjectID(rawValue: appUser),
            operatorIdentity: operatorString.flatMap { $0.isEmpty ? nil : BoardObjectID(rawValue: $0) }
        )
    }

    /// `[code_hosting.github.connections.<name>]`, zero or more: the registry of Code Hosting Connections.
    /// Each carries a required `type`, `"gh"` or `"keychain"`; a `keychain` entry also carries a required
    /// `credential`, which a `gh` entry may not (it holds no token). The Mac holds at most one `gh` entry.
    ///
    /// `[code_hosting]`, `[code_hosting.github]` and `[code_hosting.github.connections]` may each be absent
    /// or empty.
    private func codeHostingConnections(in root: TOMLTable) throws(ConfigurationError) -> [CodeHostingConnection] {
        guard let codeHostingValue = root["code_hosting"] else { return [] }
        let codeHosting = try decoding.table(codeHostingValue, key: "code_hosting")
        try decoding.rejectUnknownKeys(in: codeHosting, path: "code_hosting", allowed: ["github"])
        guard let githubValue = codeHosting["github"] else { return [] }
        let github = try decoding.table(githubValue, key: "code_hosting.github")
        try decoding.rejectUnknownKeys(in: github, path: "code_hosting.github", allowed: ["connections"])
        guard let registryValue = github["connections"] else { return [] }
        let registryPath = "code_hosting.github.connections"
        let registry = try decoding.table(registryValue, key: registryPath)

        var connections: [CodeHostingConnection] = []
        var firstGitHubCLI: (connection: String, line: Int)?
        for entry in registry.entries {
            let path = TOMLKey.path(registryPath, entry.key)
            let table = try decoding.table(entry.value, key: path)
            guard !entry.key.isEmpty else {
                throw decoding.error(line: entry.value.line, key: path, .emptyString)
            }
            let connection = try codeHostingConnection(named: entry.key, in: table, path: path)
            if case .githubCLI = connection.kind {
                let typeLine = table["type"]?.line ?? table.line
                if let first = firstGitHubCLI {
                    throw decoding.error(
                        line: typeLine, key: TOMLKey.path(path, "type"),
                        .duplicateGitHubCLIConnection(firstConnection: first.connection, firstLine: first.line)
                    )
                }
                firstGitHubCLI = (entry.key, typeLine)
            }
            connections.append(connection)
        }
        return connections
    }

    private func codeHostingConnection(
        named name: String, in table: TOMLTable, path: String
    ) throws(ConfigurationError) -> CodeHostingConnection {
        try decoding.rejectUnknownKeys(in: table, path: path, allowed: ["type", "credential"])
        let type = try decoding.requiredString("type", in: table, path: path)
        let typeLine = table["type"]?.line ?? table.line
        switch type {
        case "gh":
            // A `gh` connection holds no token, so a credential has nothing to refer to.
            if let credential = table["credential"] {
                throw decoding.error(line: credential.line, key: TOMLKey.path(path, "credential"), .unknownKey)
            }
            return CodeHostingConnection(name: name, kind: .githubCLI)
        case "keychain":
            let credentialString = try decoding.requiredString("credential", in: table, path: path)
            guard let credential = CredentialReference(credentialString) else {
                let line = table["credential"]?.line ?? table.line
                throw decoding.error(line: line, key: TOMLKey.path(path, "credential"), .emptyString)
            }
            return CodeHostingConnection(name: name, kind: .keychainToken(credential))
        default:
            throw decoding.error(line: typeLine, key: TOMLKey.path(path, "type"), .invalidCodeHostingType(type))
        }
    }

    private func cliAdapters(in root: TOMLTable) throws(ConfigurationError) -> [CLIAdapterDeclaration] {
        guard let value = root["cli"] else { return [] }
        let adapters = try decoding.table(value, key: "cli")
        var declarations: [CLIAdapterDeclaration] = []
        for entry in adapters.entries {
            let path = TOMLKey.path("cli", entry.key)
            let declaration = try decoding.table(entry.value, key: path)
            guard !entry.key.isEmpty else {
                throw decoding.error(line: entry.value.line, key: path, .emptyString)
            }
            try decoding.rejectUnknownKeys(in: declaration, path: path, allowed: ["executable"])
            let executable = try decoding.optionalString("executable", in: declaration, path: path)
            declarations.append(CLIAdapterDeclaration(name: entry.key, executable: executable))
        }
        return declarations
    }
}
