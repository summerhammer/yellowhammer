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

    @Test("Multiple Cards in the same repository reading their own repository with empty scope do not overlap (#611)")
    func sameRepositoryCardsWithSelfContractsAndEmptyScopeDoNotOverlap() throws {
        let overlaps = ContractOverlapCheck.overlaps(in: breakdown([
            try card("Create a draft Contract on the iPhone", in: "ios", reads: [
                ContractDraft(repository: "ios", paths: ["Contract.swift"])
            ]),
            try card("Manage the Invitation from a draft Contract on the iPhone", in: "ios", reads: [
                ContractDraft(repository: "ios", paths: ["Contract.swift"])
            ])
        ]))
        #expect(overlaps.isEmpty)
    }

    @Test("Multiple Cards in the same repository with explicit overlapping Declared Scope do not overlap")
    func sameRepositoryCardsWithExplicitOverlappingScopeDoNotOverlap() throws {
        let firstTitle = "Create a draft Contract on the iPhone"
        let secondTitle = "Manage the Invitation from a draft Contract on the iPhone"
        let cards = [
            try card(firstTitle, in: "ios", reads: [
                ContractDraft(repository: "ios", paths: ["Sources/Contract.swift"])
            ]),
            try card(secondTitle, in: "ios", reads: [
                ContractDraft(repository: "ios", paths: ["Sources/Contract.swift"])
            ])
        ]
        let overlaps = ContractOverlapCheck.overlaps(
            in: breakdown(cards),
            scopes: [
                firstTitle: ["Sources/Contract.swift"],
                secondTitle: ["Sources/Contract.swift"]
            ],
            emptyScopeReadsAsWholeRepository: false
        )
        #expect(overlaps.isEmpty)
    }

    @Test("Same-repository Cards with a cross-repository contract only report the cross-repository overlap")
    func sameRepositoryCardsStillCatchCrossRepositoryOverlap() throws {
        let firstTitle = "Create a draft Contract on the iPhone"
        let secondTitle = "Manage the Invitation from a draft Contract on the iPhone"
        let overlaps = ContractOverlapCheck.overlaps(in: breakdown([
            try card(firstTitle, in: "ios", reads: [
                ContractDraft(repository: "ios", paths: ["Contract.swift"])
            ]),
            try card(secondTitle, in: "ios", reads: [
                ContractDraft(repository: "ios", paths: ["Contract.swift"]),
                ContractDraft(repository: "api", paths: ["InvitationEndpoint.swift"])
            ]),
            try card("Expose Invitation endpoint", in: "api")
        ]))
        #expect(overlaps == [
            ContractOverlap(
                readerTitle: secondTitle, writerTitle: "Expose Invitation endpoint", repository: "api",
                paths: ["InvitationEndpoint.swift"]
            )
        ])
    }

    @Test("AuthoringTransaction authors and repairs a multi-Card single-repository Feature with self-contracts (#611)")
    func transactionAuthorsAndRepairsMultiCardSameRepositoryFeature() async throws {
        let firstTitle = "Create a draft Contract on the iPhone"
        let secondTitle = "Manage the Invitation from a draft Contract on the iPhone"
        let iosBreakdown = breakdown([
            try card(firstTitle, in: "ios", reads: [ContractDraft(repository: "ios", paths: ["Contract.swift"])]),
            try card(secondTitle, in: "ios", reads: [ContractDraft(repository: "ios", paths: ["Contract.swift"])])
        ])
        let selection = SelectedFeature(
            name: try #require(FeatureName(rawValue: "FEAT-1")), reasoning: "Because.", sequence: nil,
            repositories: ["ios"], adoptedCardIssueIDs: []
        )

        // 1. Fresh AuthoringTransaction.author accepts the 2-Card single-repo breakdown in authoredOrder 1 and 2.
        let freshRig = try await AuthoringRig(drafting: ScriptedBreakdown(iosBreakdown))
        let freshContext = try iosContext(freshRig, night: "2026-10-01")
        let transaction = try #require(freshRig.selection.transaction)
        #expect(try await transaction.author(selection, reselectionDepth: 0, context: freshContext) == .authored)
        #expect(!((try freshRig.journal.events()).contains { $0.type == .featureAuthoringHalted }))
        let freshRows = try cardRows(freshRig.journal)
        #expect(freshRows.map(\.repository) == ["ios", "ios"])
        #expect(freshRows.map(\.authoredOrder) == [1, 2])
        #expect(freshRows.map(\.title) == [firstTitle, secondTitle])

        // 2. A Feature previously halted with breakdown-consumes-own-feature-work (#611) repairs cleanly when moved
        //    back to Todo, reusing the halted Feature Card and both draft Work Cards in authoredOrder 1 and 2.
        try await assertPreviouslyHaltedSameRepoFeatureRepairs(
            selection: selection, breakdown: iosBreakdown, titles: [firstTitle, secondTitle]
        )
    }
}

private func assertPreviouslyHaltedSameRepoFeatureRepairs(
    selection: SelectedFeature, breakdown: FeatureBreakdown, titles: [String]
) async throws {
    let rig = try await AuthoringRig(drafting: ScriptedBreakdown(breakdown))
    let reading = FakeReadingBoard.quiet(40)
    await rig.boards.provisioning.seed(state: "Backlog", team: teamID, category: .backlog)
    try await reading.readThrough(rig.boards)
    await reading.scanLinkedIssues()

    let haltedContext = try iosContext(rig, reading: reading, night: "2026-10-01")
    let legacyCause = AuthoringHaltCause.breakdownConsumesOwnFeatureWork(overlaps: [
        ContractOverlap(readerTitle: titles[0], writerTitle: titles[1], repository: "ios", paths: ["Contract.swift"])
    ])
    #expect(try await AuthoringHalt.record(
        feature: selection.name, cause: legacyCause, selection: selection, breakdown: breakdown, context: haltedContext
    ) == .halted)

    let halt = try #require(try rig.journal.authoringHalts(feature: selection.name).last)
    let featureIssueID = BoardObjectID(rawValue: try #require(halt.issueID))
    let draftChildren = await rig.boards.writing.liveIssues.filter { $0.parent == featureIssueID }
    #expect(draftChildren.count == 2)

    let scope = try await BoardStateScope.resolve(using: rig.boards.provisioning)
    _ = try await rig.boards.writing.updateIssue(
        featureIssueID, BoardIssueChange(workflowState: try scope.id(for: .todo))
    )

    let repairContext = try iosContext(rig, reading: reading, night: "2026-10-02", previous: haltedContext)
    try await HaltedFeatureRepair.observe(context: repairContext)
    #expect(try await rig.selection.selectAndAuthor(repairContext) == .authored)

    let clearedHalt = try #require(try rig.journal.authoringHalts(feature: selection.name).last)
    #expect(clearedHalt.state == .cleared)
    let (inFlight, _) = try #require(try rig.journal.inFlightFeature())
    #expect(inFlight.issueID == featureIssueID.rawValue)
    let repairedRows = try cardRows(rig.journal)
    #expect(repairedRows.map(\.repository) == ["ios", "ios"])
    #expect(repairedRows.map(\.authoredOrder) == [1, 2])
    #expect(repairedRows.map(\.title) == titles)
    #expect(Set(repairedRows.map(\.issueID)) == Set(draftChildren.map(\.id.rawValue)))
}

private func iosContext(
    _ rig: AuthoringRig, reading: FakeReadingBoard = FakeReadingBoard([]), night: String, previous: ActContext? = nil
) throws -> ActContext {
    if let previous { try rig.journal.releaseActLease(runID: previous.runID) }
    let runID = RunID()
    guard case .claimed = try rig.journal.claimActLease(act: .author, runID: runID, mode: .rehearsal) else {
        throw JournalError.actLeaseLost(runID: runID, holder: nil)
    }
    let opening = try rig.journal.openNight(
        nightStart: try #require(NightStart(rawValue: night)), mode: .rehearsal, act: .author, runID: runID
    )
    let repositories = ProjectRepositories(
        workingRepos: [Repo(name: "ios", path: "/repos/ios", role: .mobile)],
        specSource: SpecSource(path: "/repos/spec")
    )
    let mainlines = selectionMainlines(forWorkingRepos: ["ios"])
    return ActContext(
        act: .author, mode: .rehearsal, trigger: .scheduled, runID: runID, journal: rig.journal,
        night: opening.night,
        outbox: Outbox(
            journal: rig.journal, board: rig.boards.writing, runID: runID, act: .author, nightID: opening.night.id
        ),
        board: ActBoard(reading: reading, writing: rig.boards.writing, provisioning: rig.boards.provisioning),
        mainlines: mainlines, workspace: nil, repositories: repositories,
        featureBases: selectionFeatureBases(mainlines)
    )
}
