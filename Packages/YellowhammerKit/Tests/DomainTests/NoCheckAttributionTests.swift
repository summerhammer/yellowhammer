@testable import Domain
import Testing

// verification/verify-a-feature-clause-by-clause: a Repo that declares `check = none` has no recorded Check and
// covers no clause, so a `not checked` build or test clause there is a configuration gap, not a broken sandbox.

@Suite("Not checked: attribution to a declared check = none")
struct NoCheckAttributionTests {
    @Test("The declaration names one, two or three repositories with matching grammar")
    func declarationGrammar() {
        #expect(NoCheckAttribution.declaration(repositories: []).isEmpty)
        #expect(NoCheckAttribution.declaration(repositories: ["a"]) == "`a` declares `check = none`")
        #expect(NoCheckAttribution.declaration(repositories: ["a", "b"]) == "`a` and `b` declare `check = none`")
        #expect(
            NoCheckAttribution.declaration(repositories: ["a", "b", "c"]) == "`a`, `b`, and `c` declare `check = none`"
        )
    }

    @Test("No repository declaring none gives no heading note and no hint")
    func nothingWhenNoneDeclared() {
        #expect(NoCheckAttribution.headingNote(repositories: []) == nil)
        #expect(NoCheckAttribution.hint(repositories: []) == nil)
    }

    @Test("The heading note and hint point at the Repo's Check, not the sandbox")
    func notePointsAtConfiguration() {
        #expect(
            NoCheckAttribution.headingNote(repositories: ["seshes-darwin"])
                == "no automated Check configured: `seshes-darwin` declares `check = none`"
        )
        let hint = NoCheckAttribution.hint(repositories: ["seshes-darwin"])
        #expect(hint?.contains("`seshes-darwin` declares `check = none`") == true)
        #expect(hint?.contains("set its Check in the Project's configuration") == true)
    }

    @Test("The verifier's instruction marks a declared-none repository and makes the config choice the lead")
    func instructionLeadsWithConfigurationChoice() throws {
        let route = try #require(Route(cli: "claude", model: "opus", effort: "high"))
        let instruction = VerificationInstruction(
            route: route, featureTitle: "Feature", clauses: [],
            specificationSource: .specSource(SpecSource(path: "/spec")),
            repositories: [
                VerificationRepository(
                    name: "seshes-darwin", directory: "/darwin", featureBranch: "feature", checkDeclaredNone: true
                ),
                VerificationRepository(name: "backend", directory: "/backend", featureBranch: "feature")
            ]
        )
        let rendered = instruction.render()
        let declared = "- seshes-darwin\n  Finished code: /darwin\n  Feature Branch: feature\n  Check: none"
        let undeclared = "- backend\n  Finished code: /backend\n  Feature Branch: feature\n  Check: none"
        #expect(rendered.contains(declared))
        #expect(!rendered.contains(undeclared))
        #expect(rendered.contains("`what_was_checked` must open with that configuration choice"))
        #expect(rendered.contains(NoCheckAttribution.verifierLead(repository: "<name>")))
        let lead = rendered.range(of: "must open with that configuration choice")
        let capability = rendered.range(of: "the capability your environment lacked last")
        #expect(try #require(lead).lowerBound < #require(capability).lowerBound)
    }
}
