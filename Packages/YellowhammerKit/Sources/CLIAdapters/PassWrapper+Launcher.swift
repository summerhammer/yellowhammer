import Foundation

/// The terminal-side half of the wrapper boundary: the command line a tab runs to start it. Kept
/// apart from `PassWrapper.swift`, which tests compile standalone into a fork-safe harness.
extension PassWrapper {
    // swiftlint:disable function_parameter_count
    /// POSIX-shell-safe terminal command with individually quoted arguments; caller supplies fresh
    /// private record paths and preserves the CLI's inherited tab environment.
    public static func launcherCommand(
        yhExecutable: String, cliExecutable: String, cliArguments: [String],
        identityFile: URL, endingFile: URL, signalFile: URL, stdoutFile: URL, workingDirectory: URL
    ) -> String {
        ([yhExecutable, "--_pass-wrapper", cliExecutable, identityFile.path, endingFile.path,
          signalFile.path, stdoutFile.path, workingDirectory.path] + cliArguments)
            .map(shellQuote).joined(separator: " ")
    }
    // swiftlint:enable function_parameter_count

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
