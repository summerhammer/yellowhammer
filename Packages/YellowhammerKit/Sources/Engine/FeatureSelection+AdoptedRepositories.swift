import Domain
import Foundation

// feature-authoring/select-the-next-feature#adopted-repository (OQ195 item 2; Lane-less Repository Checkout Ruling 2026-11-02):
// A Feature's selected repositories always include the repository of every Work Card it adopts.
// When the selection leaves one out, the engine adds it before the Repo Dependency and release-gate checks run.

extension FeatureSelection {
    /// The outcome of resolving adoptions for a Feature selection: candidate IDs are narrowed,
    /// and every adopted candidate's repository is added to the selected repositories.
    struct AdoptedRepositoryResolution: Equatable {
        let repositories: [String]
        let adopted: [String]
        let unadopted: [String]
    }

    /// Narrows adoption candidates to those requested by `selected`, computes the unadopted candidate IDs,
    /// and widens the selected repositories with every adopted candidate's repository (deduplicated and sorted).
    static func resolveAdoptedRepositories(
        selected: SelectedFeature,
        candidates: [AdoptionCandidate]
    ) -> AdoptedRepositoryResolution {
        let candidateIDs = Set(candidates.map(\.issueID))
        let adopted = Set(selected.adoptedCardIssueIDs).intersection(candidateIDs).sorted()
        let adoptedSet = Set(adopted)
        let unadopted = candidates.map(\.issueID).filter { !adoptedSet.contains($0) }.sorted()

        let adoptedRepos = candidates.filter { adoptedSet.contains($0.issueID) }.map(\.repository)
        let repositories = Set(selected.repositories).union(adoptedRepos).sorted()

        return AdoptedRepositoryResolution(
            repositories: repositories,
            adopted: adopted,
            unadopted: unadopted
        )
    }
}
