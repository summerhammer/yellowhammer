import CryptoKit
import Foundation

/// The slash-free name Yellowhammer requests from Orca ADE for a Feature's Worktree in every
/// repository, `yh-<project>-<feature>`.
///
/// Orca ADE derives the branch from it but may precede it with `<prefix>/`, so the name is not
/// the Feature Branch — that is what Orca ADE reports, recorded per (Feature, repository).
public struct WorktreeName: RawRepresentable, Hashable, Sendable {
    /// Leaves room below the filesystem's 255-byte component limit for Orca ADE suffixes.
    private static let maximumBytes = 200
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(projectID: ProjectID, feature: FeatureName) {
        self.init(project: projectID.rawValue, feature: feature.rawValue)
    }

    /// `featureIssueID` distinguishes separate Features (and their Cycles) with the same title.
    /// It is omitted only by callers that need the legacy short naming convention.
    public init(project: String, feature: String, featureIssueID: String? = nil) {
        let sanitizedProject = Self.sanitize(project)
        let sanitizedFeature = Self.sanitize(feature)
        let stem = "yh-\(sanitizedProject)-\(sanitizedFeature)"
        self.rawValue = Self.bounded(
            stem, identity: [project, feature] + (featureIssueID.map { [$0] } ?? []),
            requiringSuffix: featureIssueID != nil
        )
    }

    /// Bounds a legacy stored name only when it exceeds the current budget. Loading a raw value
    /// preserves it verbatim; the allocator chooses this name only when it can preserve branch identity.
    public func bounded(featureIssueID: String) -> Self {
        guard rawValue.utf8.count > Self.maximumBytes else { return self }
        return Self(rawValue: Self.bounded(
            Self.sanitize(rawValue), identity: [rawValue, featureIssueID], requiringSuffix: true
        ))
    }

    private static func bounded(_ stem: String, identity: [String], requiringSuffix: Bool) -> String {
        guard requiringSuffix || stem.utf8.count > maximumBytes else { return stem }
        // Length framing keeps field boundaries distinct; the digest covers the untruncated inputs,
        // including Unicode and characters that sanitize to the same ASCII spelling.
        let framed = identity.map { "\($0.utf8.count):\($0)" }.joined()
        let digest = SHA256.hash(data: Data(framed.utf8)).prefix(12)
            .map { String(format: "%02x", $0) }.joined()
        // sanitize emits ASCII only, so characters and bytes have the same length here.
        return "\(stem.prefix(maximumBytes - digest.count - 1))-\(digest)"
    }

    private static func sanitize(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let replaced = trimmed.unicodeScalars.map { scalar -> Character in
            switch scalar {
            case "A"..."Z", "a"..."z", "0"..."9", "_", "-":
                return Character(String(scalar))
            default:
                return "-"
            }
        }
        let result = String(replaced)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return result.isEmpty ? "unnamed" : result
    }
}

extension WorktreeName: CustomStringConvertible {
    public var description: String { rawValue }
}
