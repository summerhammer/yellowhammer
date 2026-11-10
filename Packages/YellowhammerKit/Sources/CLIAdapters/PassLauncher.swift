import Foundation

/// Generates and writes `launcher.sh` in the pass's run directory (ADR-007 items 4 & 5).
public enum PassLauncher {
    /// Standard filename for the launcher script.
    public static let fileName = "launcher.sh"

    /// Generates the content of `launcher.sh`.
    ///
    /// Exports only the variables the adapter adds to the dispatch environment, never the engine's
    /// whole environment (item 5). The CLI inherits the tab's own environment.
    /// Runs the wrapper with the spec file, and returns (never `exec`s, so the tab's shell stays).
    public static func script(
        wrapperExecutable: String,
        specPath: String,
        addedEnvironment: [String: String]
    ) -> String {
        var lines: [String] = ["#!/bin/bash"]
        for (key, value) in addedEnvironment.sorted(by: { $0.key < $1.key }) {
            lines.append("export \(key)=\(shellQuote(value))")
        }
        lines.append("\(shellQuote(wrapperExecutable)) pass-wrapper \(shellQuote(specPath))")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Writes `launcher.sh` to the given file URL with permissions 0700.
    public static func writeLauncher(
        to fileURL: URL,
        wrapperExecutable: String,
        specPath: String,
        addedEnvironment: [String: String]
    ) throws {
        let content = script(
            wrapperExecutable: wrapperExecutable,
            specPath: specPath,
            addedEnvironment: addedEnvironment
        )
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fileURL.path)
    }

    /// Safely quotes an argument for POSIX shells by single-quoting and escaping embedded single quotes.
    public static func shellQuote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
