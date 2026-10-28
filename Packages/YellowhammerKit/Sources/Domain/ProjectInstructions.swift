import Foundation

/// The size rules for Project instructions.
public enum ProjectInstructions {
    /// The most UTF-8 bytes a Project's instructions may hold.
    public static let maximumByteCount = 32_768

    /// Counts UTF-8 bytes, whitespace and line breaks included. Never the character count.
    public static func validate(_ text: String) -> ProjectInstructionsValidation {
        let byteCount = text.utf8.count
        return byteCount > maximumByteCount ? .tooLarge(byteCount: byteCount) : .accepted(byteCount: byteCount)
    }

    /// True when the text is empty after trimming whitespace and newlines. Empty means shipped behaviour.
    public static func isEmpty(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public enum ProjectInstructionsValidation: Equatable, Sendable {
    case accepted(byteCount: Int)
    case tooLarge(byteCount: Int)
}

/// One saved revision of a Project's instructions.
public struct ProjectInstructionsRevision: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let text: String
    public let savedAt: Date
    /// The default version of each production family the Operator reviewed when saving.
    public let reviewedDefaultVersions: [PromptFamily: Int]

    public init(id: String, text: String, savedAt: Date, reviewedDefaultVersions: [PromptFamily: Int]) {
        self.id = id
        self.text = text
        self.savedAt = savedAt
        self.reviewedDefaultVersions = reviewedDefaultVersions
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, savedAt, reviewedDefaultVersions
    }

    /// Decodes the versions from a string-keyed object; families this build does not know are ignored.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        text = try container.decode(String.self, forKey: .text)
        savedAt = try container.decode(Date.self, forKey: .savedAt)
        let raw = try container.decode([String: Int].self, forKey: .reviewedDefaultVersions)
        var versions: [PromptFamily: Int] = [:]
        for (key, value) in raw {
            if let family = PromptFamily(rawValue: key) {
                versions[family] = value
            }
        }
        reviewedDefaultVersions = versions
    }

    /// Encodes the versions as an object keyed by the families' raw values.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(text, forKey: .text)
        try container.encode(savedAt, forKey: .savedAt)
        let raw = Dictionary(uniqueKeysWithValues: reviewedDefaultVersions.map { ($0.key.rawValue, $0.value) })
        try container.encode(raw, forKey: .reviewedDefaultVersions)
    }

    /// The families, in `PromptFamily.allCases` order, whose default version differs from the one reviewed.
    public func defaultChanges(
        current: [PromptFamily: Int] = PromptFamily.productionDefaultVersions
    ) -> [ProjectInstructionsDefaultChange] {
        PromptFamily.allCases.compactMap { family in
            guard family.acceptsProjectInstructions, let currentVersion = current[family] else { return nil }
            let reviewed = reviewedDefaultVersions[family]
            guard reviewed != currentVersion else { return nil }
            return ProjectInstructionsDefaultChange(
                family: family, reviewedVersion: reviewed, currentVersion: currentVersion
            )
        }
    }
}

/// A family whose default prompt changed since the saved revision was reviewed.
public struct ProjectInstructionsDefaultChange: Equatable, Sendable {
    public let family: PromptFamily
    public let reviewedVersion: Int?
    public let currentVersion: Int

    public init(family: PromptFamily, reviewedVersion: Int?, currentVersion: Int) {
        self.family = family
        self.reviewedVersion = reviewedVersion
        self.currentVersion = currentVersion
    }
}

/// What is saved for a Project.
public enum ProjectInstructionsRead: Equatable, Sendable {
    case absent
    case saved(ProjectInstructionsRevision)
    case unavailable(cause: String)
}

public enum ProjectInstructionsSave: Equatable, Sendable {
    case saved(ProjectInstructionsRevision)
    case cleared
    case conflict(current: ProjectInstructionsRead)
    case tooLarge(byteCount: Int, limit: Int)
    case failed(cause: String)
}

public enum ProjectInstructionsReset: Equatable, Sendable {
    case cleared
    case failed(cause: String)
}
