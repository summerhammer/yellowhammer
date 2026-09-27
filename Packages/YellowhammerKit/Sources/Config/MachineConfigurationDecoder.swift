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
        try decoding.rejectUnknownKeys(in: root, path: nil, allowed: ["linear", "github", "cli", "routing"])
        let linear = try linear(in: root)
        let gitHubCredential = try decoding.credential(in: root, table: "github")
        let cliAdapters = try cliAdapters(in: root)
        var routingDecoding = decoding
        routingDecoding.declaredCLIAdapters = Set(cliAdapters.map(\.name))
        return MachineConfiguration(
            linearCredential: linear.credential,
            linearWorkspace: linear.workspace,
            linearAppUser: linear.appUser,
            gitHubCredential: gitHubCredential,
            cliAdapters: cliAdapters,
            routingTable: try routingDecoding.routingTable(in: root),
            operatorIdentity: linear.operatorIdentity
        )
    }

    // MARK: - Sections

    /// `[linear]`'s decoded fields: the credential, the Installation's workspace and app user ids (nil
    /// until installed), and the optional Operator identity (`operator`).
    private struct LinearSection {
        let credential: CredentialReference
        let workspace: BoardObjectID?
        let appUser: BoardObjectID?
        let operatorIdentity: BoardObjectID?
    }

    /// `[linear]`: the credential, the Installation's `workspace`/`app_user` (both nil until P17.6
    /// installs one), and the optional Operator identity (`operator`). An absent or empty `operator`
    /// decodes to nil — never a load-time validation failure (Operator Identity Ruling — 2026-09-23).
    /// A `client_id` key — the withdrawn client-credentials setup — is a named load failure (P17.4).
    ///
    /// Decoded here rather than through ``ConfigurationDecoding/credential(in:table:)``, which must keep
    /// refusing every key but `credential` in `[github]`.
    private func linear(in root: TOMLTable) throws(ConfigurationError) -> LinearSection {
        guard let value = root["linear"] else {
            throw decoding.error(line: 1, key: "linear", .missingTable)
        }
        let table = try decoding.table(value, key: "linear")
        if let legacy = table["client_id"] {
            throw decoding.error(line: legacy.line, key: "linear.client_id", .legacyLinearClientID)
        }
        try decoding.rejectUnknownKeys(
            in: table, path: "linear", allowed: ["credential", "workspace", "app_user", "operator"]
        )
        let credentialString = try decoding.requiredString("credential", in: table, path: "linear")
        guard let credential = CredentialReference(credentialString) else {
            let line = table["credential"]?.line ?? table.line
            throw decoding.error(line: line, key: "linear.credential", .emptyString)
        }
        let workspaceString = try decoding.optionalString("workspace", in: table, path: "linear", allowEmpty: true)
        let workspace = workspaceString.flatMap { $0.isEmpty ? nil : BoardObjectID(rawValue: $0) }
        let appUserString = try decoding.optionalString("app_user", in: table, path: "linear", allowEmpty: true)
        let appUser = appUserString.flatMap { $0.isEmpty ? nil : BoardObjectID(rawValue: $0) }
        let operatorString = try decoding.optionalString("operator", in: table, path: "linear", allowEmpty: true)
        let operatorIdentity = operatorString.flatMap { $0.isEmpty ? nil : BoardObjectID(rawValue: $0) }
        return LinearSection(
            credential: credential, workspace: workspace, appUser: appUser, operatorIdentity: operatorIdentity
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
