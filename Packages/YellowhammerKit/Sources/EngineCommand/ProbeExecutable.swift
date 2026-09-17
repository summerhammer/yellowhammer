/// Resolves the absolute path `yh probe` spawns for one CLI: the machine configuration's declared
/// executable wins when present, otherwise a `PATH` search for an executable named `name`. A pure
/// function so `EngineCommandTests` can exercise it without depending on the filesystem or on
/// `CLIAdapters` (MB2: only `EngineCommand` may wire an adapter).
enum ProbeExecutable {
    static func resolve(
        name: String,
        declared: String?,
        path: String?,
        fileExists: (String) -> Bool
    ) -> String? {
        if let declared, !declared.isEmpty {
            return declared
        }
        guard let path else { return nil }
        for directory in path.split(separator: ":") {
            guard !directory.isEmpty else { continue }
            let candidate = "\(directory)/\(name)"
            if fileExists(candidate) {
                return candidate
            }
        }
        return nil
    }
}
