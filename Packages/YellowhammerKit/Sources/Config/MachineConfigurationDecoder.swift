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
        let (linearClientID, linearCredential) = try linear(in: root)
        let gitHubCredential = try decoding.credential(in: root, table: "github")
        let cliAdapters = try cliAdapters(in: root)
        var routingDecoding = decoding
        routingDecoding.declaredCLIAdapters = Set(cliAdapters.map(\.name))
        return MachineConfiguration(
            linearClientID: linearClientID,
            linearCredential: linearCredential,
            gitHubCredential: gitHubCredential,
            cliAdapters: cliAdapters,
            routingTable: try routingDecoding.routingTable(in: root)
        )
    }

    // MARK: - Sections

    /// `[linear]`: the credential, then the registered application's non-empty `client_id`.
    ///
    /// Decoded here rather than through ``ConfigurationDecoding/credential(in:table:)``, which must keep
    /// refusing every key but `credential` in `[github]`.
    private func linear(in root: TOMLTable) throws(ConfigurationError) -> (String, CredentialReference) {
        guard let value = root["linear"] else {
            throw decoding.error(line: 1, key: "linear", .missingTable)
        }
        let table = try decoding.table(value, key: "linear")
        try decoding.rejectUnknownKeys(in: table, path: "linear", allowed: ["client_id", "credential"])
        let credentialString = try decoding.requiredString("credential", in: table, path: "linear")
        guard let credential = CredentialReference(credentialString) else {
            let line = table["credential"]?.line ?? table.line
            throw decoding.error(line: line, key: "linear.credential", .emptyString)
        }
        let clientID = try decoding.requiredString("client_id", in: table, path: "linear")
        return (clientID, credential)
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
