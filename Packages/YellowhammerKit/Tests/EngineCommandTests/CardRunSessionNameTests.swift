import Config
import Domain
@testable import Engine
import Foundation
@testable import Journal
import Testing

@Suite("Agent session name in Engine dispatches (AC named-session)")
struct CardRunSessionNameTests {
    private func makeRun(
        dispatch: any AgentDispatch,
        resolver: RouteResolver = cardRunResolver(),
        reviewRoundsMax: Int = 2,
        attemptsPerWorkCard: Int = 3
    ) -> CardRun {
        let log = CallLog()
        return CardRun(
            resolver: resolver,
            dispatch: dispatch,
            check: RecordingCheck(log: log),
            checks: ["backend": .none],
            reviewRoundsMax: reviewRoundsMax,
            attemptsPerWorkCard: attemptsPerWorkCard,
            passTimeoutMinutes: 60,
            resetting: RecordingAttemptResetting()
        )
    }

    private func twoRouteResolver() -> RouteResolver {
        cardRunResolver(table: RoutingTable(entries: [
            RoutingEntry(kind: Kind("card")!, route: cardRunOpus, fallbacks: [cardRunFallback])
        ]))
    }

    private func authoringInstruction(pass: RunPass, route: Route) -> AuthoringInstruction {
        AuthoringInstruction(
            pass: pass,
            route: route,
            specificationSource: .specSource(SpecSource(path: "/spec")),
            specificationMainline: nil,
            repos: [],
            mainlines: ResolvedMainlines(),
            namedFeature: nil,
            adoptionCandidates: [],
            selectedFeature: nil
        )
    }

    @Test("Card run requests carry displayIdentifier, repo, Round 1 and Attempt 1")
    func cardRunRequestsCarrySessionName() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open(), cards: [("BACK-1", "backend")])
        let dispatch = LoggingDispatch(log: CallLog())
        let cardRun = makeRun(dispatch: dispatch)

        try await cardRun.run("BACK-1", in: world)

        let projectID = world.journal.projectID.rawValue
        let card = try world.card("BACK-1")
        let base = "YH · \(projectID) · \(card.displayIdentifier) · \(card.repository)"

        let architect = try #require(dispatch.requests.passes(.architect).first)
        #expect(architect.sessionName == "\(base) · architect · Round 1 · Attempt 1")

        let worker = try #require(dispatch.requests.passes(.worker).first)
        #expect(worker.sessionName == "\(base) · worker · Round 1 · Attempt 1")

        let reviewer = try #require(dispatch.requests.passes(.reviewer).first)
        #expect(reviewer.sessionName == "\(base) · reviewer · Round 1 · Attempt 1")
    }

    @Test("A second Attempt retries and its requests carry Attempt 2")
    func secondAttemptCarriesAttemptTwo() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open(), cards: [("BACK-1", "backend")])
        let dispatch = SequencedDispatch(sequences: [.worker: [.workerFailed, .workerCompleted]])
        let cardRun = makeRun(dispatch: dispatch, resolver: twoRouteResolver())

        try await cardRun.run("BACK-1", in: world)

        let projectID = world.journal.projectID.rawValue
        let card = try world.card("BACK-1")
        let base = "YH · \(projectID) · \(card.displayIdentifier) · \(card.repository)"

        let workers = dispatch.requests.passes(.worker)
        #expect(workers.count == 2)
        #expect(workers[0].sessionName == "\(base) · worker · Round 1 · Attempt 1")
        #expect(workers[1].sessionName == "\(base) · worker · Round 1 · Attempt 2")

        let architects = dispatch.requests.passes(.architect)
        #expect(architects.count == 2)
        #expect(architects[0].sessionName == "\(base) · architect · Round 1 · Attempt 1")
        #expect(architects[1].sessionName == "\(base) · architect · Round 1 · Attempt 2")
    }

    @Test("A review Round resumes the worker and its request carries Round 2")
    func reviewRoundResumedWorkerCarriesRoundTwo() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open(), cards: [("BACK-1", "backend")])
        let dispatch = SequencedDispatch(
            sequences: [
                .worker: [.workerCompleted, .workerCompleted],
                .reviewer: [.reviewerChangesRequested, .reviewerApproved]
            ]
        )
        let cardRun = makeRun(dispatch: dispatch)

        try await cardRun.run("BACK-1", in: world)

        let projectID = world.journal.projectID.rawValue
        let card = try world.card("BACK-1")
        let base = "YH · \(projectID) · \(card.displayIdentifier) · \(card.repository)"

        let workers = dispatch.requests.passes(.worker)
        #expect(workers.count == 2)
        #expect(workers[0].sessionName == "\(base) · worker · Round 1 · Attempt 1")
        #expect(workers[1].sessionName == "\(base) · worker · Round 2 · Attempt 1")
    }

    @Test("Authoring selection and breakdown passes carry their session names")
    func authoringPassesCarrySessionNames() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let context = try makeSelectionContext(journal, repositories: selectionRepositories()).context
        let projectID = journal.projectID.rawValue

        let authoring = AuthoringRoute(
            resolver: RouteResolver(
                table: RoutingTable(entries: [RoutingEntry(kind: .authoring, route: cardRunOpus)])
            ) { _ in .offered },
            dispatch: LoggingDispatch(log: CallLog(), script: .empty)
        )

        let selectionResult = try await authoring.run(
            pass: .selection,
            worktreePath: "/tmp",
            context: context
        ) { route, _ in
            self.authoringInstruction(pass: .selection, route: route)
        }
        #expect(selectionResult != nil)

        let breakdownResult = try await authoring.run(
            pass: .breakdown,
            worktreePath: "/tmp",
            context: context
        ) { route, _ in
            self.authoringInstruction(pass: .breakdown, route: route)
        }
        #expect(breakdownResult != nil)

        let loggingDispatch = try #require(authoring.dispatch as? LoggingDispatch)
        let requests = loggingDispatch.requests.all
        #expect(requests.count == 2)
        #expect(requests[0].pass == .selection)
        #expect(requests[0].sessionName == "YH · \(projectID) · selection")
        #expect(requests[1].pass == .breakdown)
        #expect(requests[1].sessionName == "YH · \(projectID) · breakdown")
    }

    @Test("Verifier pass carries project, feature display identifier and verifier")
    func verifierPassCarriesSessionName() async throws {
        let world = try await VerificationWorld()
        try world.addClause(issue: "BACK-1", cid: "c1")
        try world.addAttempt(card: "BACK-1", route: routeWriter)
        let dispatch = ScriptedVerifierDispatch([routeOther: .judgeAll()])
        let resolver = verificationResolver(primary: routeWriter, fallbacks: [routeOther])

        let verdict = try await world.verification(resolver: resolver, dispatch: dispatch)
            .verify(world.featureContext)

        #expect(verdict.allClausesMet)
        let verifierRequest = try #require(dispatch.requests.first)
        #expect(verifierRequest.pass == .verifier)

        let projectID = world.journal.projectID.rawValue
        let featureID = world.featureContext.feature.displayIdentifier
        #expect(verifierRequest.sessionName == "YH · \(projectID) · \(featureID) · verifier")
    }
}
