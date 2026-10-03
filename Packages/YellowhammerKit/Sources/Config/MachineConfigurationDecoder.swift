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
        try decoding.rejectUnknownKeys(in: root, path: nil, allowed: ["board", "github", "cli", "routing"])
        let linearInstallations = try linearInstallations(in: root)
        let gitHubCredential = try decoding.credential(in: root, table: "github")
        let cliAdapters = try cliAdapters(in: root)
        var routingDecoding = decoding
        routingDecoding.declaredCLIAdapters = Set(cliAdapters.map(\.name))
        return MachineConfiguration(
            linearInstallations: linearInstallations,
            gitHubCredential: gitHubCredential,
            cliAdapters: cliAdapters,
            routingTable: try routingDecoding.routingTable(in: root)
        )
    }

    // MARK: - Sections

    /// `[board.linear.installations.<name>]`, zero or more: the registry of App Installations. Each
    /// carries a required `credential`, `workspace` and `app_user` and an optional Operator identity
    /// (`operator`). An absent or empty `operator` decodes to nil — never a load-time validation failure
    /// (Operator Identity Ruling — 2026-09-23). Two entries may not share a `workspace`.
    ///
    /// `[board]`, `[board.linear]` and `[board.linear.installations]` may each be absent or empty.
    private func linearInstallations(in root: TOMLTable) throws(ConfigurationError) -> [LinearInstallation] {
        guard let boardValue = root["board"] else { return [] }
        let board = try decoding.table(boardValue, key: "board")
        try decoding.rejectUnknownKeys(in: board, path: "board", allowed: ["linear"])
        guard let linearValue = board["linear"] else { return [] }
        let linear = try decoding.table(linearValue, key: "board.linear")
        try decoding.rejectUnknownKeys(in: linear, path: "board.linear", allowed: ["installations"])
        guard let registryValue = linear["installations"] else { return [] }
        let registry = try decoding.table(registryValue, key: "board.linear.installations")

        var installations: [LinearInstallation] = []
        var firstWorkspaces: [String: (installation: String, line: Int)] = [:]
        for entry in registry.entries {
            let path = TOMLKey.path("board.linear.installations", entry.key)
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
            in: table, path: path, allowed: ["credential", "workspace", "app_user", "operator"]
        )
        let credentialString = try decoding.requiredString("credential", in: table, path: path)
        guard let credential = CredentialReference(credentialString) else {
            let line = table["credential"]?.line ?? table.line
            throw decoding.error(line: line, key: TOMLKey.path(path, "credential"), .emptyString)
        }
        let workspace = try decoding.requiredString("workspace", in: table, path: path)
        let appUser = try decoding.requiredString("app_user", in: table, path: path)
        let operatorString = try decoding.optionalString("operator", in: table, path: path, allowEmpty: true)
        return LinearInstallation(
            name: name,
            credential: credential,
            workspace: BoardObjectID(rawValue: workspace),
            appUser: BoardObjectID(rawValue: appUser),
            operatorIdentity: operatorString.flatMap { $0.isEmpty ? nil : BoardObjectID(rawValue: $0) }
        )
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
