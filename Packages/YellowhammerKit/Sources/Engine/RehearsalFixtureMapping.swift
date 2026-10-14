import Domain

/// How a rehearsal Night's selection and breakdown fixtures are re-aimed at the Project they run on
/// (#440). The shipped fixtures name repositories `fixture-backend`, `fixture-web`, `fixture-mobile` and
/// cite `fixture-epic/fixture-story` and `fixture-epic/fixture-story-2`; on a Project that has none of
/// those, selection would halt as `contract-outside-project` and every citation would be uncitable. This
/// pure value maps each canonical fixture name onto one of the Project's own repositories or spec story
/// IDs, so ``RehearsalDispatch`` can answer with names that exist.
///
/// The rule, per list and in canonical order: a fixture name that is one of the Project's own maps to
/// itself (so the P15.3 fixture tree, and every test built on it, is unchanged); otherwise it maps to the
/// next Project name not yet claimed, and once those run out it wraps around the Project's names in
/// declared order. No Project names means no mapping at all. A name outside the canonical lists passes
/// through unchanged.
struct RehearsalFixtureMapping: Equatable, Sendable {
    static let fixtureRepositories = ["fixture-backend", "fixture-web", "fixture-mobile"]
    static let fixtureCitations = ["fixture-epic/fixture-story", "fixture-epic/fixture-story-2"]

    let repositories: [String: String]
    let citations: [String: String]

    /// `repos` is the Project's working repositories in declared order (a `.spec` role repo is never a
    /// target); `storyIDs` the `<epic>/<story>` IDs of its specification, sorted.
    init(repos: [Repo], storyIDs: [String]) {
        self.repositories = Self.assign(
            canonical: Self.fixtureRepositories, available: repos.filter { $0.role != .spec }.map(\.name)
        )
        self.citations = Self.assign(canonical: Self.fixtureCitations, available: storyIDs)
    }

    private static func assign(canonical: [String], available: [String]) -> [String: String] {
        guard !available.isEmpty else { return [:] }
        let claimed = Set(canonical.filter(available.contains))
        var unclaimed = available.filter { !claimed.contains($0) }
        var wrapIndex = 0
        var mapping: [String: String] = [:]
        for name in canonical {
            if available.contains(name) {
                mapping[name] = name
            } else if !unclaimed.isEmpty {
                mapping[name] = unclaimed.removeFirst()
            } else {
                mapping[name] = available[wrapIndex % available.count]
                wrapIndex += 1
            }
        }
        return mapping
    }

    private func repository(_ name: String) -> String { repositories[name] ?? name }

    private func citation(_ citation: SpecCitation) -> SpecCitation {
        citations[citation.rawValue].map { SpecCitation(rawValue: $0) } ?? citation
    }

    /// `selected` with its repositories mapped (duplicates dropped, first-seen order); every other field kept.
    func apply(to selected: SelectedFeature) -> SelectedFeature {
        var seen = Set<String>()
        let mapped = selected.repositories.map(repository).filter { seen.insert($0).inserted }
        return SelectedFeature(
            name: selected.name, reasoning: selected.reasoning, sequence: selected.sequence,
            repositories: mapped, adoptedCardIssueIDs: selected.adoptedCardIssueIDs
        )
    }

    /// `breakdown` with every Card and Contract repository and every Definition of Done citation mapped.
    func apply(to breakdown: FeatureBreakdown) -> FeatureBreakdown {
        FeatureBreakdown(
            definitionOfDone: breakdown.definitionOfDone.map(apply),
            cards: breakdown.cards.map { card in
                CardDraft(
                    repository: repository(card.repository), kind: card.kind, title: card.title,
                    unitOfWork: card.unitOfWork, brief: card.brief,
                    definitionOfDone: card.definitionOfDone.map(apply),
                    contracts: card.contracts.map {
                        ContractDraft(
                            repository: repository($0.repository), paths: $0.paths, ranges: $0.ranges,
                            symbol: $0.symbol
                        )
                    }
                )
            }
        )
    }

    private func apply(_ clause: DefinitionOfDoneClauseDraft) -> DefinitionOfDoneClauseDraft {
        DefinitionOfDoneClauseDraft(text: clause.text, citation: citation(clause.citation))
    }
}
