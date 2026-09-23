import Domain
@testable import Engine
import Foundation
@testable import Journal
import Testing

// roadmap P9.11 (glossary: Rehearsal Night): a rehearsal Night substitutes nothing special for the author
// Act — selection and breakdown are agent CLI dispatches, fixtured by the rule that already exists
// (RehearsalDispatch plus the shipped result-file fixtures). Only that the fixtures round-trip is asserted,
// never the quality of a selection or breakdown.

@Suite("Authoring in a Rehearsal Night (P9.11)")
struct AuthoringRehearsalTests {
    private static let table = RoutingTable(entries: [
        RoutingEntry(kind: .authoring, route: Route(cli: "claude", model: "opus", effort: "high")!)
    ])

    private static func repositories() -> ProjectRepositories {
        ProjectRepositories(
            workingRepos: [Repo(name: "fixture-backend", path: "/repos/fixture-backend", role: .backend)],
            specSource: SpecSource(path: "/repos/spec")
        )
    }

    @Test("Selection and breakdown come from the fixtures: no agent CLI is dispatched, and the Journal records both")
    func rehearsalAuthorsFromFixtures() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBuildActBoards()
        let dispatch = RehearsalDispatch()
        let route = AuthoringRoute(
            resolver: RouteResolver(table: Self.table) { _ in .offered }, dispatch: dispatch
        )
        let selection = FeatureSelection(
            selector: RoutedFeatureSelector(route: route),
            transaction: AuthoringTransaction(
                drafting: RoutedFeatureBreakdown(route: route),
                citations: FakeCitationResolver(resolvable: ["fixture-epic/fixture-story"]),
                transcribing: FakeContractTranscriber(), provenance: FakeProvenanceTester()
            )
        )
        let (context, _) = try makeSelectionContext(
            journal, repositories: Self.repositories(), boards: boards
        )

        let outcome = try await selection.selectAndAuthor(context)

        #expect(outcome == .authored)
        let answered = dispatch.answered
        #expect(answered.map(\.pass) == [.selection, .breakdown])
        #expect(answered.allSatisfy { $0.issueID == "authoring" })

        // Every authoring dispatch was answered by a fixture, and none by a process.
        let dispatched = try journal.events(ofType: .authoringDispatched).map(\.event)
        #expect(dispatched == [
            .authoringDispatched(
                pass: .selection, route: "claude/opus/high", ordinal: 1,
                fixture: RehearsalResultFixture.selectionSelected.rawValue
            ),
            .authoringDispatched(
                pass: .breakdown, route: "claude/opus/high", ordinal: 1,
                fixture: RehearsalResultFixture.breakdownDrafted.rawValue
            )
        ])
        #expect(try journal.events(ofType: .agentCLIProcessSpawned).isEmpty)

        let selected = try #require(try journal.events(ofType: .featureSelected).first)
        guard case .featureSelected(let payload) = selected.event else {
            Issue.record("expected featureSelected")
            return
        }
        #expect(payload.name == "Fixture Feature: rehearsal selection")
        #expect(payload.repositories == ["fixture-backend"])
    }

    @Test("A Rehearsal Night's reports all carry the fixture origin")
    func reportsCarryTheFixtureOrigin() async throws {
        let dispatch = RehearsalDispatch()
        for pass in [RunPass.selection, .breakdown] {
            let report = try await dispatch.dispatch(AgentDispatchRequest(
                runID: RunID(), issueID: "authoring", attemptID: 1,
                route: Route(cli: "claude", model: "opus", effort: "high")!, pass: pass,
                instruction: .authoring(AuthoringInstruction(
                    pass: pass, route: Route(cli: "claude", model: "opus", effort: "high")!,
                    specificationSource: .specSource(SpecSource(path: "/repos/spec")),
                    specificationMainline: nil, repos: [], mainlines: ResolvedMainlines(), namedFeature: nil,
                    adoptionCandidates: [], selectedFeature: nil, resultFilePath: ""
                )),
                worktreePath: "/repos/spec"
            ))
            guard case .rehearsalFixture = report.origin else {
                Issue.record("expected a rehearsal fixture origin for \(pass)")
                return
            }
        }
    }

    @Test("A drafted Card carrying the reserved authoring Kind is rejected as an authoring fault")
    func reservedKindIsRejected() async throws {
        let rig = try await AuthoringRig(drafting: ScriptedBreakdown(FeatureBreakdown(
            definitionOfDone: [authoringClause("x")],
            cards: [CardDraft(
                repository: "backend", kind: Kind.authoring, title: "Sneaky", unitOfWork: "x", brief: "Approach.",
                definitionOfDone: [authoringClause("x")]
            )]
        )))

        let outcome = try await rig.run(rig.context())

        #expect(outcome == .authoringRolledBack)
        #expect(try tableRowCount(rig.journal, table: "outbox") == 0)
        let rejected = try #require(try rig.journal.events(ofType: .featureBreakdownRejected).first)
        guard case .featureBreakdownRejected(_, let reason) = rejected.event else {
            Issue.record("expected featureBreakdownRejected")
            return
        }
        #expect(reason.contains("reserved"))
    }
}
