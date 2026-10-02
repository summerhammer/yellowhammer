import Config
import Domain
import Foundation

/// A draft that is complete: every step passes.
func completeAddProjectDraft() -> AddProjectDraft {
    var draft = AddProjectDraft()
    draft.setName("Acme")
    draft.linearProjectID = "ACME"
    draft.addRepo(path: "/work/acme-backend")
    draft.repos[0].check = "make test"
    draft.useSpecSource("/work/acme-spec")
    return draft
}
