import Domain
@testable import Engine
import Foundation
@testable import Journal
import Testing

// roadmap P19.2: the pull request title is the Project's Message Template, rendered with the Feature's
// primary epic. Pure rendering; the seam tests live in PullRequestTitleSeamTests.

@Suite("Pull request title (P19.2)")
struct PullRequestTitleTests {
    private func citations(_ raw: String...) -> [SpecCitation] { raw.map { SpecCitation($0) } }

    @Test("primary epic: the spec's tie example resolves to the epic cited first")
    func tieGoesToTheEarlierEpic() {
        let spec = citations("auth/a", "billing/b", "billing/c", "auth/d")
        #expect(PullRequestTitle.primaryEpic(citations: spec) == "auth")
        let reversed = citations("billing/x", "auth/a", "auth/b", "billing/y")
        #expect(PullRequestTitle.primaryEpic(citations: reversed) == "billing")
    }

    @Test("primary epic: a later, more-cited epic beats an earlier one")
    func moreCitedWins() {
        #expect(PullRequestTitle.primaryEpic(citations: citations("auth/a", "billing/b", "billing/c")) == "billing")
    }

    @Test("primary epic: goal citations are ignored, and none at all gives no epic")
    func goalCitationsIgnored() {
        #expect(PullRequestTitle.primaryEpic(citations: citations("G1", "{#g5}", "goals")) == nil)
        #expect(PullRequestTitle.primaryEpic(citations: []) == nil)
        #expect(PullRequestTitle.primaryEpic(citations: citations("G1", "G2", "G3", "auth/a")) == "auth")
    }

    private func inputs(partial: Bool = false, epic: String? = "auth") -> PullRequestTitle.Inputs {
        PullRequestTitle.Inputs(
            featureTitle: "Title", featureKey: "YLH-42", repository: "backend", branch: "yh-proj-feat",
            projectID: "proj", isPartialLanding: partial, primaryEpic: epic
        )
    }

    @Test("the default template renders type, scope, Partial Landing and title")
    func defaultTemplate() {
        let template = MessageTemplate.default(.pullRequestTitle)
        #expect(PullRequestTitle.render(template: template, changeType: .feat, inputs: inputs()) == "feat(auth): Title")
        #expect(
            PullRequestTitle.render(template: template, changeType: .feat, inputs: inputs(partial: true))
                == "feat(auth): partial landing: Title"
        )
        #expect(
            PullRequestTitle.render(template: template, changeType: .feat, inputs: inputs(epic: nil)) == "feat: Title"
        )
    }

    @Test("a custom template fills every token, with a non-default Change Type")
    func customTemplate() throws {
        let template = try MessageTemplate(
            "{type}: [{key}] {title} @{repository} {branch} #{project}", kind: .pullRequestTitle
        )
        let fix = try #require(ChangeType("fix"))
        #expect(
            PullRequestTitle.render(template: template, changeType: fix, inputs: inputs())
                == "fix: [YLH-42] Title @backend yh-proj-feat #proj"
        )
    }

    @Test("clause order follows description markers, then numeric cid; never lexical cid")
    func clauseOrder() {
        func clause(_ cid: String) -> ClauseRecord {
            ClauseRecord(
                cid: cid, issueID: "FEAT-1", level: "feature", text: "t", locationID: "auth/a",
                provenance: "p", citationProvenance: "p", invalidated: false, deleted: false, createdAt: Date()
            )
        }
        let clauses = ["c1", "c10", "c2", "c3"].map(clause)
        #expect(PullRequestTitle.inClauseOrder(clauses, description: nil).map(\.cid) == ["c1", "c2", "c3", "c10"])
        let description = "- [ ] <!-- yh:clause:c3 --> x\n- [ ] <!-- yh:clause:c10 --> y"
        #expect(
            PullRequestTitle.inClauseOrder(clauses, description: description).map(\.cid) == ["c3", "c10", "c1", "c2"]
        )
    }
}
