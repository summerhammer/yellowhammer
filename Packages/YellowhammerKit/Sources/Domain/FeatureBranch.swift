import Foundation

/// A deterministic, slash-free branch name for a Feature in a repository.
///
/// Feature branches follow the naming pattern `yh-<project>-<feature>`, matching Orca ADE's
/// worktree naming deterministically without slashes.
public struct FeatureBranch: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public var name: String { rawValue }

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(name: String) {
        self.rawValue = name
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

extension FeatureBranch: CustomStringConvertible {
    public var description: String { rawValue }
}

extension FeatureBranch: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }
}
