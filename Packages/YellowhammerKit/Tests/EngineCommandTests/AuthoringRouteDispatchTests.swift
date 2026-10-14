import Config
import Domain
@testable import Engine
import Foundation
@testable import Journal
import Synchronization
import Testing

// roadmap P9.11: the author Act's routed dispatch walks the entry's configured fallback order through the
// ordinary resolver, and an exhausted or crashed dispatch is an authoring fault (P9.10), not a throw. The
// content of a selection or breakdown is model-authored and is never asserted here — only which Route was
// dispatched next, and what the Journal and Night Card say about a fault.

private let primary = Route(cli: "claude", model: "opus", effort: "high")!
private let fallback = Route(cli: "codex", model: "gpt-5.4", effort: "high")!

/// What a scripted Route does when dispatched.
private enum Behaviour {
    case refuse
    case exit(Int32)
    case crash
    case answer(DispatchResult)
}

private let selectionFailed = DispatchResult.selection(SelectionResult(outcome: .failed(reason: "unreadable")))
private let nothingSelectable = DispatchResult.selection(SelectionResult(outcome: .noSelectableFeature))

/// An `AgentDispatch` answering per Route and recording every request in order.
private final class ScriptedRouteDispatch: AgentDispatch, Sendable {
    private let behaviours: [Route: Behaviour]
    private let log = Mutex<[AgentDispatchRequest]>([])

    init(_ behaviours: [Route: Behaviour]) {
        self.behaviours = behaviours
    }

    var requests: [AgentDispatchRequest] { log.withLock { $0 } }

    func dispatch(_ request: AgentDispatchRequest) async throws -> AgentDispatchReport {
        log.withLock { $0.append(request) }
        switch behaviours[request.route] ?? .refuse {
        case .refuse:
            throw AgentDispatchRefusal(reason: "no executable")
        case .exit(let status):
            return AgentDispatchReport(outcome: .failed(exitStatus: status))
        case .crash:
            return AgentDispatchReport(outcome: .crashedUnknown(.signaled(9)))
        case .answer(let result):
            return AgentDispatchReport(outcome: .completed(result))
        }
    }
}

private func authoringRoute(_ dispatch: any AgentDispatch) -> AuthoringRoute {
    let table = RoutingTable(entries: [
        RoutingEntry(kind: .authoring, route: primary, fallbacks: [fallback])
    ])
    return AuthoringRoute(resolver: RouteResolver(table: table) { _ in .offered }, dispatch: dispatch)
}

private final class Rig {
    /// Owns the Journal's directory: it is removed when the fixture goes away.
    let fixture: OutboxJournalFixture
    let journal: JournalStore
    let context: ActContext
    let dispatch: ScriptedRouteDispatch
    let selection: FeatureSelection
    let transaction = ScriptedSelectedFeatureAuthoring()

    init(_ behaviours: [Route: Behaviour]) throws {
        fixture = try OutboxJournalFixture()
        journal = try fixture.open()
        context = try makeSelectionContext(journal, repositories: selectionRepositories()).context
        dispatch = ScriptedRouteDispatch(behaviours)
        selection = FeatureSelection(
            selector: RoutedFeatureSelector(route: authoringRoute(dispatch)), transaction: transaction
        )
    }
}

@Suite("Authoring route: fallback order and faults (P9.11)")
struct AuthoringRouteDispatchTests {
    @Test("Authoring receives existing absolute directories from home paths in Project configuration",
          arguments: [false, true])
    func configuredHomePathsReachDispatch(specRepo: Bool) async throws {
        let name = ".yellowhammer-path-test-\(UUID().uuidString)"
        let directory = FileManager.default.homeDirectoryForCurrentUser.appending(path: name)
        let backend = directory.appending(path: "backend")
        let spec = directory.appending(path: "spec")
        try FileManager.default.createDirectory(at: backend, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: spec, withIntermediateDirectories: true)
        let configuration = ProjectConfiguration(
            id: try #require(ProjectID(rawValue: "home-paths")), name: "Home paths",
            linearInstallationName: "acme", linearProject: "HOME", codeHostingConnectionName: "github",
            specSource: specRepo ? nil : "~/\(name)/spec",
            repos: [RepoDeclaration(name: "backend", path: "~/\(name)/backend", role: .backend, check: .none)]
                + (specRepo ? [RepoDeclaration(name: "spec", path: "~/\(name)/spec", role: .spec, check: .none)] : [])
        )
        let fixture = try OutboxJournalFixture()
        let context = try makeSelectionContext(fixture.open(), repositories: configuration.repositories).context
        let dispatch = ScriptedRouteDispatch([primary: .answer(nothingSelectable)])
        let selection = FeatureSelection(
            selector: RoutedFeatureSelector(route: authoringRoute(dispatch)),
            transaction: ScriptedSelectedFeatureAuthoring()
        )

        _ = try await selection.selectAndAuthor(context)

        let request = try #require(dispatch.requests.first)
        #expect(request.worktreePath == spec.path(percentEncoded: false))
        #expect(request.additionalReadableDirectories == configuration.repos.map {
            directory.appending(path: $0.name).path(percentEncoded: false)
        })
        #expect(FileManager.default.fileExists(atPath: request.worktreePath))
        #expect(request.additionalReadableDirectories.allSatisfy { FileManager.default.fileExists(atPath: $0) })
    }

    @Test(
        "A capability failure of the primary Route dispatches the first fallback next",
        arguments: [
            Behaviour.refuse, Behaviour.exit(2), Behaviour.answer(selectionFailed)
        ]
    )
    fileprivate func primaryFailureFallsBack(primaryBehaviour: Behaviour) async throws {
        let rig = try Rig([primary: primaryBehaviour, fallback: .answer(nothingSelectable)])

        let outcome = try await rig.selection.selectAndAuthor(rig.context)

        #expect(outcome == .noWorkAvailable)
        let requests = rig.dispatch.requests
        #expect(requests.map(\.route) == [primary, fallback])
        #expect(requests.map(\.attemptID) == [1, 2])
        #expect(requests.allSatisfy { $0.issueID == "authoring" && $0.pass == .selection })
        #expect(requests.allSatisfy { $0.worktreePath == "/repos/spec" })
        #expect(requests.allSatisfy { $0.additionalReadableDirectories == ["/repos/backend", "/repos/mobile"] })
    }

    @Test("A Crashed-Unknown run excludes nothing and ends authoring: the fallback is never tried, no throw")
    func crashedUnknownStops() async throws {
        let rig = try Rig([primary: .crash, fallback: .answer(nothingSelectable)])

        let outcome = try await rig.selection.selectAndAuthor(rig.context)

        #expect(outcome == .authoringRolledBack)
        #expect(rig.dispatch.requests.map(\.route) == [primary])
        #expect(try rig.journal.events(ofType: .featureSelectionFailed).count == 1)
        #expect(rig.transaction.callCount == 0)
    }

    @Test("Exhaustion records the fault and the author Act ends without throwing, and without a quiet verdict")
    func exhaustionIsAnAuthoringFault() async throws {
        let rig = try Rig([primary: .exit(1), fallback: .refuse])

        try await AuthorAct(authoring: rig.selection).run(rig.context)

        #expect(rig.dispatch.requests.map(\.route) == [primary, fallback])
        let failed = try #require(try rig.journal.events(ofType: .featureSelectionFailed).first)
        guard case .featureSelectionFailed(let reason) = failed.event else {
            Issue.record("expected featureSelectionFailed")
            return
        }
        #expect(reason.contains("no Route left"))
        #expect(try rig.journal.events(ofType: .authoringNoWorkAvailable).isEmpty)
        #expect(try rig.journal.events(ofType: .featureAuthoringHalted).isEmpty)

        let line = try #require(NightCardMaintenance.authoringLine(for: failed.event))
        #expect(line.contains("Selecting a Feature failed"))
        #expect(!line.contains("quiet Night"))
        #expect(!line.lowercased().contains("halt"))
    }

    @Test("Each dispatched authoring pass is recorded with its pass, Route and origin")
    func dispatchIsRecorded() async throws {
        let rig = try Rig([primary: .exit(1), fallback: .answer(nothingSelectable)])

        _ = try await rig.selection.selectAndAuthor(rig.context)

        let recorded = try rig.journal.events(ofType: .authoringDispatched).map(\.event)
        #expect(recorded == [
            .authoringDispatched(pass: .selection, route: primary.description, ordinal: 1, fixture: nil),
            .authoringDispatched(pass: .selection, route: fallback.description, ordinal: 2, fixture: nil)
        ])
    }

    @Test("A Work Card over the description budget is invalid output: the next Route is tried")
    func overBudgetWorkCardTriesTheNextRoute() async throws {
        let rig = try await AuthoringRig()
        rig.descriptionBudget = try DescriptionBudget(
            configured: 2_000, limit: BoardDescriptionLimit(maximum: 250_000, unit: .utf16CodeUnits)
        )
        let dispatch = ScriptedRouteDispatch([
            primary: .answer(try briefedBreakdown(String(repeating: "Approach. ", count: 400))),
            fallback: .answer(try briefedBreakdown("Approach."))
        ])

        let outcome = try await rangedSelection(dispatch).selectAndAuthor(try rig.context())

        #expect(outcome == .authored)
        #expect(dispatch.requests.map(\.route) == [primary, fallback])
        #expect(try rig.journal.events(ofType: .featureBreakdownRejected).isEmpty)
    }

    @Test("The widest Route is taken from the whole Routing Table, fallbacks included")
    func widestRouteSpansTheTable() {
        let drafting = RoutedFeatureBreakdown(route: authoringRoute(ScriptedRouteDispatch([:])))
        #expect(drafting.widestRoute == [primary, fallback].max { $0.description.count < $1.description.count })
    }

    @Test("A breakdown that no Route answers is an authoring fault: the transaction records it and ends")
    func breakdownExhaustionEndsTheAct() async throws {
        let rig = try await AuthoringRig()
        let dispatch = ScriptedRouteDispatch([primary: .exit(1), fallback: .answer(
            .breakdown(BreakdownResult(outcome: .failed(reason: "no plan")))
        )])
        let transaction = AuthoringTransaction(
            drafting: RoutedFeatureBreakdown(route: authoringRoute(dispatch)),
            citations: FakeCitationResolver(), transcribing: FakeContractTranscriber(),
            provenance: FakeProvenanceTester()
        )
        let selection = FeatureSelection(
            selector: ScriptedFeatureSelector(outcome: .selected(try authoringSelection())),
            transaction: transaction
        )

        let outcome = try await selection.selectAndAuthor(try rig.context())

        #expect(outcome == .authoringRolledBack)
        #expect(dispatch.requests.map(\.route) == [primary, fallback])
        #expect(dispatch.requests.allSatisfy { $0.pass == .breakdown })
        #expect(dispatch.requests.allSatisfy {
            $0.additionalReadableDirectories == ["/repos/backend", "/repos/mobile"]
        })
        #expect(try rig.journal.events(ofType: .featureBreakdownRejected).count == 1)
        #expect(try tableRowCount(rig.journal, table: "outbox") == 0)
    }

    @Test("A breakdown naming a contract range out of bounds is invalid output: the next Route is tried")
    func outOfBoundsRangeTriesTheNextRoute() async throws {
        let rig = try await AuthoringRig()
        let dispatch = ScriptedRouteDispatch([
            primary: .answer(try rangedBreakdown(LineRange(start: 900, end: 950))),
            fallback: .answer(try rangedBreakdown(LineRange(start: 10, end: 20)))
        ])

        let outcome = try await rangedSelection(dispatch).selectAndAuthor(try rig.context())

        #expect(outcome == .authored)
        #expect(dispatch.requests.map(\.route) == [primary, fallback])
        #expect(try rig.journal.events(ofType: .featureBreakdownRejected).isEmpty)
        #expect(try rig.journal.events(ofType: .featureAuthoringHalted).isEmpty)
        let card = try #require(try rig.journal.cards().first { $0.title == "Ranged" })
        let block = try #require(try rig.journal.transcriptionBlocks(cardID: card.id).first)
        #expect(block.ranges == ["api.json": [LineRange(start: 10, end: 20)]])
    }

    @Test("""
        When every Route names a range out of bounds, it is an authoring fault naming the path, the range \
        and the file's line count; never an Authoring Halt, and nothing reaches the Outbox
        """)
    func outOfBoundsOnEveryRouteIsAnAuthoringFault() async throws {
        let rig = try await AuthoringRig()
        let dispatch = ScriptedRouteDispatch([
            primary: .answer(try rangedBreakdown(LineRange(start: 900, end: 950))),
            fallback: .answer(try rangedBreakdown(LineRange(start: 99, end: 101)))
        ])

        let outcome = try await rangedSelection(dispatch).selectAndAuthor(try rig.context())

        #expect(outcome == .authoringRolledBack)
        #expect(dispatch.requests.map(\.route) == [primary, fallback])
        #expect(try rig.journal.events(ofType: .featureAuthoringHalted).isEmpty)
        #expect(try tableRowCount(rig.journal, table: "outbox") == 0)
        let rejected = try #require(try rig.journal.events(ofType: .featureBreakdownRejected).first)
        guard case .featureBreakdownRejected(_, let reason) = rejected.event else {
            Issue.record("expected featureBreakdownRejected")
            return
        }
        #expect(reason.contains("no Route left"))
        #expect(reason.contains("api.json lines 99–101"))
        #expect(reason.contains("the file has 100 lines"))
        let line = try #require(NightCardMaintenance.authoringLine(for: rejected.event))
        #expect(!line.lowercased().contains("halt"))
    }
}

/// A drafted breakdown whose one backend Card consumes `api.json` lines `range` from `backend`.
private func rangedBreakdown(_ range: LineRange) throws -> DispatchResult {
    let card = CardDraft(
        repository: "backend", kind: try authoringKind(), title: "Ranged", unitOfWork: "Build against the API",
        brief: "Approach.", definitionOfDone: [authoringClause("Ranged is done.")],
        contracts: [ContractDraft(repository: "backend", paths: ["api.json"], ranges: ["api.json": [range]])]
    )
    let breakdown = FeatureBreakdown(definitionOfDone: [authoringClause("The Feature is done.")], cards: [card])
    return .breakdown(BreakdownResult(outcome: .drafted(breakdown)))
}

/// A selection authoring through the routed breakdown, against files of 100 lines.
private func rangedSelection(_ dispatch: ScriptedRouteDispatch) throws -> FeatureSelection {
    FeatureSelection(
        selector: ScriptedFeatureSelector(outcome: .selected(try authoringSelection())),
        transaction: AuthoringTransaction(
            drafting: RoutedFeatureBreakdown(route: authoringRoute(dispatch)), citations: FakeCitationResolver(),
            transcribing: FakeContractTranscriber(fileLineCount: 100), provenance: FakeProvenanceTester()
        )
    )
}

/// A drafted breakdown whose one backend Card carries `brief` and no contract.
private func briefedBreakdown(_ brief: String) throws -> DispatchResult {
    let card = CardDraft(
        repository: "backend", kind: try authoringKind(), title: "Briefed", unitOfWork: "Build it",
        brief: brief, definitionOfDone: [authoringClause("Briefed is done.")]
    )
    let breakdown = FeatureBreakdown(definitionOfDone: [authoringClause("The Feature is done.")], cards: [card])
    return .breakdown(BreakdownResult(outcome: .drafted(breakdown)))
}
