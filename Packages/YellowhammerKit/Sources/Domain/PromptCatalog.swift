import Foundation

/// One variant of a prompt family's shipped default template.
public struct PromptTemplateVariant: Equatable, Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public let template: String
    public let placeholders: [String]

    public init(name: String, template: String, placeholders: [String]) {
        self.name = name
        self.template = template
        self.placeholders = placeholders
    }
}

/// A catalog entry for one Yellowhammer prompt family.
public struct PromptCatalogEntry: Equatable, Sendable, Identifiable {
    public var id: PromptFamily { family }
    public let family: PromptFamily
    public let title: String
    public let purpose: String
    public let defaultVersion: Int
    public let acceptsProjectInstructions: Bool
    public let variants: [PromptTemplateVariant]

    public init(
        family: PromptFamily,
        title: String,
        purpose: String,
        defaultVersion: Int,
        acceptsProjectInstructions: Bool,
        variants: [PromptTemplateVariant]
    ) {
        self.family = family
        self.title = title
        self.purpose = purpose
        self.defaultVersion = defaultVersion
        self.acceptsProjectInstructions = acceptsProjectInstructions
        self.variants = variants
    }
}

/// Catalog of shipped default prompt templates for all Yellowhammer prompt families.
///
/// Each template is produced by invoking the real renderer with marked placeholders,
/// guaranteeing that the catalog never drifts from the engine's shipped prompt text.
public enum PromptCatalog {
    /// All prompt catalog entries, production families first, then diagnostic families.
    public static let entries: [PromptCatalogEntry] = [
        selectionEntry,
        breakdownEntry,
        architectEntry,
        workerEntry,
        reviewerEntry,
        verifierEntry,
        unattendedProbeEntry,
        sessionResumptionProbeEntry,
        routePreflightEntry,
        processContainmentProbeEntry,
        stateContainmentProbeEntry
    ]

    /// Finds the catalog entry for a prompt family.
    public static func entry(for family: PromptFamily) -> PromptCatalogEntry? {
        entries.first { $0.family == family }
    }

    static func makeVariant(
        name: String,
        template: String,
        candidatePlaceholders: [String]
    ) -> PromptTemplateVariant {
        var seen = Set<String>()
        var uniqueCandidates: [String] = []
        for candidate in candidatePlaceholders where !seen.contains(candidate) {
            seen.insert(candidate)
            uniqueCandidates.append(candidate)
        }

        let ordered = uniqueCandidates
            .filter { template.contains($0) }
            .sorted {
                let r1 = template.range(of: $0)!.lowerBound
                let r2 = template.range(of: $1)!.lowerBound
                return r1 < r2
            }

        return PromptTemplateVariant(name: name, template: template, placeholders: ordered)
    }
}
