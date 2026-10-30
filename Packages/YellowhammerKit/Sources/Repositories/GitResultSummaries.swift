import Foundation

extension GitCommandResult {
    /// git's own stderr, trimmed, saying why it failed; `fallback` when it printed nothing.
    public func failureReason(fallback: String) -> String {
        let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? fallback : message
    }
}

/// How a commit is abbreviated wherever the engine names one to the Operator.
public enum GitCommit {
    /// The first seven characters of `commit`.
    public static func short(_ commit: String) -> String {
        String(commit.prefix(7))
    }
}
