import CryptoKit
import Foundation

/// The delimiter fence around a Managed Block: the Outbox replaces only the text between the two
/// markers and leaves everything outside them byte-identical to the pre-flight read. When either
/// marker is missing or the pair is malformed, nothing is written — a description is never guessed at.
public enum ManagedBlockFence {
    public static let start = "<!-- yh:managed:start -->"
    public static let end = "<!-- yh:managed:end -->"

    /// Why a description cannot be fenced.
    public enum Failure: Error, Equatable, Sendable, CustomStringConvertible {
        case noDescription
        case startMissing
        case endMissing
        case startDuplicated
        case endDuplicated
        case endBeforeStart

        public var description: String {
            switch self {
            case .noDescription: "the issue has no description"
            case .startMissing: "the `\(ManagedBlockFence.start)` delimiter is missing"
            case .endMissing: "the `\(ManagedBlockFence.end)` delimiter is missing"
            case .startDuplicated: "the `\(ManagedBlockFence.start)` delimiter appears more than once"
            case .endDuplicated: "the `\(ManagedBlockFence.end)` delimiter appears more than once"
            case .endBeforeStart: "the `\(ManagedBlockFence.end)` delimiter comes before `\(ManagedBlockFence.start)`"
            }
        }
    }

    /// A fenced rewrite, ready to send.
    public struct Replacement: Equatable, Sendable {
        /// The whole description to write.
        public let description: String
        /// Everything outside the delimiters — the human's prose — exactly as it was read, with the
        /// delimiters themselves. Hashed for the Journal's audit record of the write.
        public let preservedProse: String

        public var preservedProseHash: String { ManagedBlockFence.sha256(preservedProse) }
    }

    /// Replaces the text between the delimiters of `description` with `rendered`, on its own lines.
    public static func replace(in description: String?, rendered: String) -> Result<Replacement, Failure> {
        guard let description else { return .failure(.noDescription) }
        let starts = description.ranges(of: start)
        let ends = description.ranges(of: end)
        guard let startRange = starts.first else { return .failure(.startMissing) }
        guard let endRange = ends.first else { return .failure(.endMissing) }
        guard starts.count == 1 else { return .failure(.startDuplicated) }
        guard ends.count == 1 else { return .failure(.endDuplicated) }
        guard startRange.upperBound <= endRange.lowerBound else { return .failure(.endBeforeStart) }

        let prefix = description[..<startRange.upperBound]
        let suffix = description[endRange.lowerBound...]
        return .success(Replacement(
            description: prefix + "\n" + rendered + "\n" + suffix,
            preservedProse: String(prefix) + String(suffix)
        ))
    }

    /// A fresh description for an issue Yellowhammer creates: the block on its own, fenced, so every
    /// later rewrite finds the delimiters it needs.
    public static func initialDescription(rendered: String) -> String {
        "\(start)\n\(rendered)\n\(end)"
    }

    /// SHA-256 of the UTF-8 bytes, as lowercase hex.
    public static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
