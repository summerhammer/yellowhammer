import Config
import Domain
import SwiftUI

extension AddProjectDraft {
    /// A realistic draft for previews: name "Acme Mobile", two repos (one conflicting), spec source, and
    /// all steps visited so problems show.
    static var preview: AddProjectDraft {
        var draft = AddProjectDraft()
        draft.setName("Acme Mobile")
        draft.context = AddProjectContext(
            existingProjectIDs: ["acme"],
            repoOwners: [
                AddProjectContext.normalizedPath("~/dev/acme/acme-backend"): "Acme"
            ],
            specSourceReaders: [
                AddProjectContext.normalizedPath("~/dev/acme/acme-spec"): ["Acme"]
            ],
            journalProjectIDs: ["acme"],
            teams: [
                SetupChoices.Team(id: "team1", key: "acme", name: "Acme"),
                SetupChoices.Team(id: "team2", key: "internal", name: "Internal")
            ],
            linearProjects: [
                SetupChoices.LinearProject(id: "lp-web", name: "Acme Web", teamNames: ["Acme"]),
                SetupChoices.LinearProject(id: "lp-ios", name: "Acme iOS", teamNames: ["Acme", "Internal"]),
                SetupChoices.LinearProject(id: "lp-ops", name: "Operations", teamNames: ["Internal"])
            ]
        )
        draft.addRepo(path: "~/dev/acme/acme-mobile")
        if !draft.repos.isEmpty {
            draft.repos[draft.repos.count - 1].check = "swift test"
        }
        draft.addRepo(path: "~/dev/acme/acme-backend")
        draft.useSpecSource("~/dev/acme/acme-spec")
        draft.visited = Set(Step.allCases)
        return draft
    }
}
