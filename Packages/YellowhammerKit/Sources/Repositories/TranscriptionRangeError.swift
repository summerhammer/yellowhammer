import Domain
import Foundation

/// A contract's line range that cannot be transcribed from the file at the resolved commit. A range is
/// never clamped to fit: the model named lines the file does not have, so the contract is unreadable and
/// the next Route gets to try (spec: feature-authoring/author-an-architectural-brief).
public enum TranscriptionRangeError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The file has no lines at all, so no range can name one.
    case emptyFile(repository: String, path: String, commit: String)
    /// The range starts before line 1.
    case startsBeforeFirstLine(repository: String, path: String, range: LineRange)
    /// The range ends before it starts.
    case reversed(repository: String, path: String, range: LineRange)
    /// The range starts or ends after the file's last line.
    case outOfBounds(repository: String, path: String, range: LineRange, lineCount: Int, commit: String)

    public var description: String {
        switch self {
        case .emptyFile(let repository, let path, let commit):
            return "\(path) is empty at \(Self.short(commit)) in \(repository), so it has no line range"
        case .startsBeforeFirstLine(let repository, let path, let range):
            return "\(path) \(LineRange.displayText([range])) starts at line \(range.start) in \(repository); "
                + "lines are numbered from 1"
        case .reversed(let repository, let path, let range):
            return "\(path) \(LineRange.displayText([range])) is reversed in \(repository): "
                + "it ends before it starts"
        case .outOfBounds(let repository, let path, let range, let lineCount, let commit):
            let noun = lineCount == 1 ? "line" : "lines"
            return "\(path) \(LineRange.displayText([range])) is out of bounds at \(Self.short(commit)): "
                + "the file has \(lineCount) \(noun) in \(repository)"
        }
    }

    private static func short(_ commit: String) -> String { String(commit.prefix(7)) }
}

extension TranscriptionRangeError {
    /// Checks every raw range against a file of `lineCount` lines; throws for the first one that does
    /// not fit. Nothing is clamped.
    static func validate(
        _ ranges: [LineRange], repository: String, path: String, lineCount: Int, commit: String
    ) throws(TranscriptionRangeError) {
        for range in ranges {
            if lineCount == 0 {
                throw .emptyFile(repository: repository, path: path, commit: commit)
            }
            if range.start < 1 {
                throw .startsBeforeFirstLine(repository: repository, path: path, range: range)
            }
            if range.end < range.start {
                throw .reversed(repository: repository, path: path, range: range)
            }
            if range.end > lineCount || range.start > lineCount {
                throw .outOfBounds(
                    repository: repository, path: path, range: range, lineCount: lineCount, commit: commit
                )
            }
        }
    }
}
