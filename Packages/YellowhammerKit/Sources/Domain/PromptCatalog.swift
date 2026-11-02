import Foundation

/// One variant of a prompt family's shipped default template.
public struct PromptTemplateVariant: Equatable, Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public let template: String
    /// The marked `⟨…⟩` placeholders filled in at dispatch, in template order.
    public let placeholders: [String]
    /// Literal sample inputs the renderer cannot mark, such as a pass timeout or a Night date, in template order.
    public let sampleValues: [String]

    public init(name: String, template: String, placeholders: [String], sampleValues: [String] = []) {
        self.name = name
        self.template = template
        self.placeholders = placeholders
        self.sampleValues = sampleValues
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
    /// The sample Repo Role the template was rendered for, or nil when the family's text does not depend on it.
    public let sampleRole: RepoRole?

    public init(
        family: PromptFamily,
        title: String,
        purpose: String,
        defaultVersion: Int,
        acceptsProjectInstructions: Bool,
        sampleRole: RepoRole? = nil,
        variants: [PromptTemplateVariant]
    ) {
        self.family = family
        self.title = title
        self.purpose = purpose
        self.defaultVersion = defaultVersion
        self.acceptsProjectInstructions = acceptsProjectInstructions
        self.sampleRole = sampleRole
        self.variants = variants
    }
}

/// Catalog of shipped default prompt templates for all Yellowhammer prompt families.
///
/// Each template is produced by invoking the real renderer with marked placeholders,
/// guaranteeing that the catalog never drifts from the engine's shipped prompt text.
public enum PromptCatalog {
    /// All prompt catalog entries, production families first, then diagnostic families.
    public static let entries: [PromptCatalogEntry] = entries(projectInstructions: nil)

    /// The same entries, built through the same real renderers, with the six production families composed
    /// with `projectInstructions` and the diagnostic families unchanged. Placeholders stay those of the
    /// shipped templates, so angle brackets in the Operator's text are never labelled.
    ///
    /// `role` is the sample Repo Role the Repo-dependent families are rendered for.
    public static func entries(projectInstructions: String?, role: RepoRole = .backend) -> [PromptCatalogEntry] {
        [
            selectionEntry(projectInstructions, role: role),
            breakdownEntry(projectInstructions, role: role),
            architectEntry(projectInstructions, role: role),
            workerEntry(projectInstructions, role: role),
            reviewerEntry(projectInstructions, role: role),
            verifierEntry(projectInstructions),
            unattendedProbeEntry,
            sessionResumptionProbeEntry,
            routePreflightEntry,
            processContainmentProbeEntry,
            stateContainmentProbeEntry
        ]
    }

    /// Finds the catalog entry for a prompt family.
    public static func entry(for family: PromptFamily) -> PromptCatalogEntry? {
        entries.first { $0.family == family }
    }

    /// Finds the catalog entry for a prompt family, rendered for the sample Repo Role `role`.
    public static func entry(for family: PromptFamily, role: RepoRole) -> PromptCatalogEntry? {
        entries(projectInstructions: nil, role: role).first { $0.family == family }
    }

    static func makeVariant(
        name: String,
        template: String,
        shippedTemplate: String? = nil,
        candidatePlaceholders: [String]
    ) -> PromptTemplateVariant {
        let source = shippedTemplate ?? template
        var seen = Set<String>()
        var uniqueCandidates: [String] = []
        for candidate in candidatePlaceholders where !seen.contains(candidate) {
            seen.insert(candidate)
            uniqueCandidates.append(candidate)
        }

        let ordered = uniqueCandidates
            .filter { source.contains($0) }
            .sorted {
                let r1 = source.range(of: $0)!.lowerBound
                let r2 = source.range(of: $1)!.lowerBound
                return r1 < r2
            }

        let isMarked = { (candidate: String) in candidate.hasPrefix("⟨") && candidate.hasSuffix("⟩") }
        return PromptTemplateVariant(
            name: name,
            template: template,
            placeholders: ordered.filter(isMarked),
            sampleValues: ordered.filter { !isMarked($0) }
        )
    }
}
