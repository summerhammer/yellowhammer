import Domain
import Foundation
import Testing

@Suite("AgentSessionName (AC named-session)")
struct AgentSessionNameTests {
    @Test("Separator is space, U+00B7 middle dot, space")
    func separatorIsMiddleDot() {
        #expect(AgentSessionName.separator == " · ")
        #expect(AgentSessionName.separator == " \u{00B7} ")
        #expect(AgentSessionName.prefix == "YH")
    }

    @Test("Work Card passes carry project, card, repo, pass, Round and Attempt")
    func workCardPassExactStrings() {
        let architect = AgentSessionName.card(
            project: "prj-alpha",
            card: "YLH-42",
            repo: "yellowhammer",
            pass: .architect,
            round: 1,
            attempt: 1
        )
        #expect(architect == "YH · prj-alpha · YLH-42 · yellowhammer · architect · Round 1 · Attempt 1")

        let worker = AgentSessionName.card(
            project: "prj-beta",
            card: "YLH-100",
            repo: "core-kit",
            pass: .worker,
            round: 2,
            attempt: 3
        )
        #expect(worker == "YH · prj-beta · YLH-100 · core-kit · worker · Round 2 · Attempt 3")

        let reviewer = AgentSessionName.card(
            project: "prj-gamma",
            card: "YLH-200",
            repo: "ui-kit",
            pass: .reviewer,
            round: 1,
            attempt: 2
        )
        #expect(reviewer == "YH · prj-gamma · YLH-200 · ui-kit · reviewer · Round 1 · Attempt 2")
    }

    @Test("Selection and breakdown passes carry project and pass")
    func authoringPassExactStrings() {
        let selection = AgentSessionName.authoring(project: "prj-alpha", pass: .selection)
        #expect(selection == "YH · prj-alpha · selection")

        let breakdown = AgentSessionName.authoring(project: "prj-alpha", pass: .breakdown)
        #expect(breakdown == "YH · prj-alpha · breakdown")

        #expect(AgentSessionName.selection(project: "prj-beta") == "YH · prj-beta · selection")
        #expect(AgentSessionName.breakdown(project: "prj-beta") == "YH · prj-beta · breakdown")
    }

    @Test("Verifier pass carries project, feature identifier and literal verifier")
    func verifierPassExactString() {
        let verifier = AgentSessionName.verifier(project: "prj-alpha", feature: "YLH-10")
        #expect(verifier == "YH · prj-alpha · YLH-10 · verifier")
    }
}
