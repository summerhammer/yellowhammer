import Domain

/// Turns a parsed TOML document into a ``MachineConfiguration``.
///
/// Within each table, unknown keys are reported first, in file order, then the known keys in a fixed order.
struct MachineConfigurationDecoder {
    private let decoding: ConfigurationDecoding

    init(file: String) {
        decoding = ConfigurationDecoding(file: file)
    }

    func decode(_ root: TOMLTable) throws(ConfigurationError) -> MachineConfiguration {
        try decoding.rejectUnknownKeys(in: root, path: nil, allowed: ["linear", "github", "cli", "routing"])
        return MachineConfiguration(
            linearCredential: try decoding.credential(in: root, table: "linear"),
            gitHubCredential: try decoding.credential(in: root, table: "github"),
            cliAdapters: try cliAdapters(in: root),
            routingTable: try decoding.routingTable(in: root)
        )
    }

    // MARK: - Sections

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
