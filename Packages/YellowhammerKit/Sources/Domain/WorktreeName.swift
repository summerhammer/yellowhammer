import Foundation

/// The slash-free name Yellowhammer requests from Orca ADE for a Feature's Worktree in every
/// repository, `yh-<project>-<feature>`.
///
/// Orca ADE derives the branch from it but may precede it with `<prefix>/`, so the name is not
/// the Feature Branch — that is what Orca ADE reports, recorded per (Feature, repository).
public struct WorktreeName: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(projectID: ProjectID, feature: FeatureName) {
        self.init(project: projectID.rawValue, feature: feature.rawValue)
    }

    public init(project: String, feature: String) {
        let sanitizedProject = Self.sanitize(project)
        let sanitizedFeature = Self.sanitize(feature)
        self.rawValue = "yh-\(sanitizedProject)-\(sanitizedFeature)"
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
