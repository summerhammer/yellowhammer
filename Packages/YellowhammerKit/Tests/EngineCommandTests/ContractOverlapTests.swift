import Domain
@testable import Engine
import Foundation
@testable import Journal
import Testing

// feature-authoring/author-the-cycle-and-card-dag, `#contract-overlap`: a Work Card reading what another Work
// Card of the same Feature writes is an Authoring Halt, found with no model call.

private func card(_ title: String, in repository: String, reads contracts: [ContractDraft] = []) throws -> CardDraft {
    CardDraft(
        repository: repository, kind: try authoringKind(), title: title, unitOfWork: "Do it", brief: "Approach.",
        definitionOfDone: [authoringClause("\(title) is done.")], contracts: contracts
    )
}

private func breakdown(_ cards: [CardDraft]) -> FeatureBreakdown {
    FeatureBreakdown(definitionOfDone: [authoringClause("The Feature is done.")], cards: cards)
}

@Suite("Contract-overlap floor")
struct ContractOverlapTests {
    @Test("A Card reading paths in a repository another Card writes overlaps, naming both Cards")
    func readerOfAnotherCardsRepository() throws {
        let overlaps = ContractOverlapCheck.overlaps(in: breakdown([
            try card("Backend one", in: "backend"),
            try card("Mobile one", in: "mobile", reads: [
                ContractDraft(repository: "backend", paths: ["API.swift", "Model.swift"])
            ])
        ]))

        #expect(overlaps == [
            ContractOverlap(
                readerTitle: "Mobile one", writerTitle: "Backend one", repository: "backend",
                paths: ["API.swift", "Model.swift"]
            )
        ])
    }

    @Test("A contract on the Spec Source never overlaps")
    func specSourceNeverOverlaps() throws {
        let overlaps = ContractOverlapCheck.overlaps(in: breakdown([
            try card("Backend one", in: "backend", reads: [ContractDraft(repository: "spec_source", paths: ["a.md"])]),
            try card("Mobile one", in: "mobile", reads: [ContractDraft(repository: "spec_source", paths: ["a.md"])])
        ]))
        #expect(overlaps.isEmpty)
    }

    @Test("A contract on a repository no Card writes overlaps nothing")
    func repositoryNoCardWrites() throws {
        let overlaps = ContractOverlapCheck.overlaps(in: breakdown([
            try card("Backend one", in: "backend"),
            try card("Mobile one", in: "mobile", reads: [ContractDraft(repository: "web", paths: ["a.swift"])])
        ]))
        #expect(overlaps.isEmpty)
    }

    @Test("A Card's own contract on its own repository is not an overlap with itself")
    func sameCardNeverOverlaps() throws {
        let overlaps = ContractOverlapCheck.overlaps(in: breakdown([
            try card("Backend one", in: "backend", reads: [ContractDraft(repository: "backend", paths: ["a.swift"])])
        ]))
        #expect(overlaps.isEmpty)
    }

    @Test("A spec-role working Repo another Card writes does overlap")
    func specRoleWorkingRepoOverlaps() throws {
        let overlaps = ContractOverlapCheck.overlaps(in: breakdown([
            try card("Spec edit", in: "spec-repo"),
            try card("Backend one", in: "backend", reads: [
                ContractDraft(repository: "spec-repo", paths: ["story.md"])
            ])
        ]))
        #expect(overlaps.map(\.writerTitle) == ["Spec edit"])
        #expect(overlaps.map(\.repository) == ["spec-repo"])
    }

    @Test("Several contracts on one writer's repository are one overlap, each path once, in contract order")
    func contractsAreMerged() throws {
        let overlaps = ContractOverlapCheck.overlaps(in: breakdown([
            try card("Backend one", in: "backend"),
            try card("Mobile one", in: "mobile", reads: [
                ContractDraft(repository: "backend", paths: ["b.swift", "a.swift"]),
                ContractDraft(repository: "backend", paths: ["a.swift", "c.swift"])
            ])
        ]))
        #expect(overlaps.map(\.paths) == [["b.swift", "a.swift", "c.swift"]])
    }

    @Test("With a Declared Scope, only paths it covers overlap")
    func declaredScopeNarrowsTheOverlap() throws {
        let cards = [
            try card("Backend one", in: "backend"),
            try card("Mobile one", in: "mobile", reads: [
                ContractDraft(
                    repository: "backend", paths: ["Sources/API/Route.swift", "Docs/readme.md", "Sources/API.swift"]
                )
            ])
        ]
        let scoped = ContractOverlapCheck.overlaps(
            in: breakdown(cards), scopes: ["Backend one": ["Sources/API", "Sources/API.swift"]]
        )
        #expect(scoped.map(\.paths) == [["Sources/API/Route.swift", "Sources/API.swift"]])

        let outside = ContractOverlapCheck.overlaps(in: breakdown(cards), scopes: ["Backend one": ["Elsewhere/"]])
        #expect(outside.isEmpty)
    }

    @Test("An empty scope reads as the whole repository by default, and as nothing when the seam says so")
    func emptyScopeSeam() throws {
        #expect(ContractOverlapCheck.emptyScopeReadsAsWholeRepository)
        let cards = [
            try card("Backend one", in: "backend"),
            try card("Mobile one", in: "mobile", reads: [ContractDraft(repository: "backend", paths: ["a.swift"])])
        ]
        #expect(ContractOverlapCheck.overlaps(in: breakdown(cards)).count == 1)
        #expect(ContractOverlapCheck.overlaps(in: breakdown(cards), emptyScopeReadsAsWholeRepository: false).isEmpty)
    }

    @Test("The halt cause names both Cards, the repository and the paths, and points to the Repo Dependency")
    func causeText() {
        let cause = AuthoringHaltCause.breakdownConsumesOwnFeatureWork(overlaps: [
            ContractOverlap(
                readerTitle: "Mobile one", writerTitle: "Backend one", repository: "backend", paths: ["a", "b"]
            )
        ])
        #expect(cause.kind == "breakdown-consumes-own-feature-work")
        #expect(cause.detail == "Mobile one|Backend one|backend|a,b")
        #expect(cause.description.hasPrefix(
            "This breakdown consumes its own Feature's work: Card 'Mobile one' reads backend (a, b), which Card "
                + "'Backend one' writes in this Feature."
        ))
        #expect(cause.description.contains("Declare the Repo Dependency (`consumes` on the consumer Repo)"))
    }

    @Test("A breakdown that consumes its own Feature's work halts: no fault, no rejection, nothing accepted")
    func transactionHalts() async throws {
        let overlapping = breakdown([
            try card("Backend one", in: "backend"),
            try card("Mobile one", in: "mobile", reads: [ContractDraft(repository: "backend", paths: ["API.swift"])])
        ])
        let rig = try await AuthoringRig(drafting: ScriptedBreakdown(overlapping))

        let outcome = try await rig.run(rig.context())

        #expect(outcome == .halted)
        let events = try rig.journal.events()
        #expect(!events.contains { $0.type == .featureBreakdownRejected })
        #expect(!events.contains { $0.type == .featureAuthoringAccepted })
        let feature = try authoringSelection().name
        #expect(try rig.journal.authoringFaultCount(feature: feature).count < 1)
        // The halt's own Waiting on You write and the breakdown's draft Work Cards (roadmap P22.6) are the only board
        // writes: no Card, no Feature row.
        #expect(try tableRowCount(rig.journal, table: "card") == 0)
        #expect(try tableRowCount(rig.journal, table: "feature") == 0)
        let issues = await rig.boards.writing.liveIssues
        #expect(issues.filter { $0.parent == nil }.map(\.title) == ["FEAT-1"])
        #expect(Set(issues.filter { $0.parent != nil }.map(\.title)) == ["Backend one", "Mobile one"])
        let halted = try #require(events.first { $0.type == .featureAuthoringHalted })
        guard case .featureAuthoringHalted(_, let kind, let detail) = halted.event else {
            Issue.record("expected featureAuthoringHalted")
            return
        }
        #expect(kind == "breakdown-consumes-own-feature-work")
        #expect(detail == "Mobile one|Backend one|backend|API.swift")

        let issue = try #require(await rig.boards.writing.liveIssues.first { $0.title == "FEAT-1" })
        #expect(try await issue.workflowState == waitingOnYouStateID(rig.boards))
        let comments = await rig.boards.writing.comments
        let body = try #require(comments.first { $0.issue == issue.id }?.body)
        for expected in ["Mobile one", "Backend one", "backend", "API.swift", "Declare the Repo Dependency"] {
            #expect(body.contains(expected))
        }
    }

    @Test("The same breakdown without the contract is authored")
    func transactionAuthorsWithoutTheContract() async throws {
        let independent = breakdown([try card("Backend one", in: "backend"), try card("Mobile one", in: "mobile")])
        let rig = try await AuthoringRig(drafting: ScriptedBreakdown(independent))

        #expect(try await rig.run(rig.context()) == .authored)
    }
}
