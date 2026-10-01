import Foundation

/// Why the commits a worker reported could not be read with `git log`.
public struct CommitTrailerReadFailure: Error, Equatable, Sendable, CustomStringConvertible {
    /// Git's stderr, trimmed.
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }

    public var description: String { reason }
}

/// Reads which of a worker's commits carry no `Yellowhammer-Card` git trailer, with the local `git`
/// executable (graph-execution/run-a-card). Only presence counts; the trailer's value is not judged.
public struct CommitTrailerReader: Sendable {
    public static let trailerKey = "Yellowhammer-Card"

    private let git: GitRunner

    public init(git: GitRunner = GitRunner()) {
        self.git = git
    }

    /// The shas, oldest first, of the commits in `base..commit` that carry no trailer. With a nil `base`
    /// only `commit` itself is read, never an open range. A non-zero git exit is a failure carrying
    /// git's stderr.
    public func commitsMissingCardTrailer(
        worktreePath: String, from base: String?, to commit: String
    ) async -> Result<[String], CommitTrailerReadFailure> {
        var arguments = [
            "-C", worktreePath, "log", "--reverse",
            "--format=%H%x1f%(trailers:key=\(Self.trailerKey),valueonly)%x1e"
        ]
        if base == nil { arguments.append("-1") }
        // The reported commit comes from a model-authored result file: never let it read as an option.
        arguments.append("--end-of-options")
        arguments.append(base.map { "\($0)..\(commit)" } ?? commit)
        let result = await git.run(arguments)
        guard result.isSuccess else {
            return .failure(CommitTrailerReadFailure(
                reason: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            ))
        }
        var missing: [String] = []
        for entry in result.stdout.split(separator: "\u{1E}") {
            let fields = entry.split(separator: "\u{1F}", maxSplits: 1, omittingEmptySubsequences: false)
            let sha = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sha.isEmpty else { continue }
            let value = fields.count > 1 ? fields[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            if value.isEmpty { missing.append(sha) }
        }
        return .success(missing)
    }
}
