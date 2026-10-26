import Config
import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
@testable import Journal
@testable import Pulse
import Repositories
import Synchronization
import Testing

@Suite("Prompt capture engine dispatch call sites")
struct PromptCaptureDispatchTests {
    private func makeCardRun(dispatch: any AgentDispatch) -> CardRun {
        CardRun(
            resolver: cardRunResolver(),
            dispatch: dispatch,
            check: RecordingCheck(log: CallLog()),
            checks: ["backend": .none],
            reviewRoundsMax: 2,
            attemptsPerWorkCard: 3,
            passTimeoutMinutes: 60,
            resetting: RecordingAttemptResetting()
        )
    }

    @Test("CardRun dispatches architect, worker (Round 1 & 2) and reviewer, journaling PromptCaptureRequested for each")
    func cardRunJournalsPromptCaptureRequested() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let world = try await makeCardRunWorld(journal: journal)

        let dispatch = SequencedDispatch(
            sequences: [
                .worker: [.workerCompleted, .workerCompleted],
                .reviewer: [.reviewerChangesRequested, .reviewerApproved]
            ]
        )
        try await makeCardRun(dispatch: dispatch).run("BACK-1", in: world)

        let requests = dispatch.requests.all
        #expect(requests.count >= 4)

        let events = try journal.events(ofType: .promptCaptureRequested)
        #expect(events.count == requests.count)

        for (request, eventRecord) in zip(requests, events) {
            let provenance = try #require(request.provenance)
            guard case .promptCaptureRequested(
                let recordID, let pass, let cardID, let issueID, let attemptID, let round, let ordinal
            ) = eventRecord.event else {
                let desc = String(describing: eventRecord.event)
                Issue.record(Comment(rawValue: "expected .promptCaptureRequested, got \(desc)"))
                continue
            }
            #expect(recordID == provenance.recordID)
            #expect(pass == request.pass)
            #expect(cardID == provenance.cardID)
            #expect(issueID == request.issueID)
            #expect(attemptID == request.attemptID)
            #expect(round == provenance.round)
            #expect(ordinal == nil)
        }
    }

    @Test("CardRun resumed worker gets Round 2 in provenance and in PromptCaptureRequested event")
    func cardRunResumedWorkerGetsRound2() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let world = try await makeCardRunWorld(journal: journal)

        let dispatch = SequencedDispatch(
            sequences: [
                .worker: [.workerCompleted, .workerCompleted],
                .reviewer: [.reviewerChangesRequested, .reviewerApproved]
            ]
        )
        try await makeCardRun(dispatch: dispatch).run("BACK-1", in: world)

        let requests = dispatch.requests.all.filter { $0.pass == .worker }
        #expect(requests.count == 2)
        let prov1 = try #require(requests[0].provenance)
        let prov2 = try #require(requests[1].provenance)
        #expect(prov1.round == 1)
        #expect(prov2.round == 2)

        let events = try journal.events(ofType: .promptCaptureRequested)
        let workerEvents = events.compactMap { record -> (round: Int?, recordID: String)? in
            guard case .promptCaptureRequested(let id, let pass, _, _, _, let round, _) = record.event,
                  pass == .worker else { return nil }
            return (round: round, recordID: id)
        }
        #expect(workerEvents.count == 2)
        #expect(workerEvents[0].round == 1)
        #expect(workerEvents[0].recordID == prov1.recordID)
        #expect(workerEvents[1].round == 2)
        #expect(workerEvents[1].recordID == prov2.recordID)
    }

    @Test("AuthoringRoute.run dispatches selection, journaling PromptCaptureRequested with matching provenance")
    func authoringSelectionJournalsPromptCaptureRequested() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBuildActBoards()
        let context = try makeSelectionContext(journal, repositories: selectionRepositories(), boards: boards).context

        let primary = Route(cli: "claude", model: "opus", effort: "high")!
        let table = RoutingTable(entries: [RoutingEntry(kind: .authoring, route: primary)])
        let capturingDispatch = CapturingAuthoringDispatch([
            .selection: DispatchResult.selection(SelectionResult(outcome: .noSelectableFeature))
        ])
        let route = AuthoringRoute(resolver: RouteResolver(table: table) { _ in .offered }, dispatch: capturingDispatch)

        let selection = FeatureSelection(
            selector: RoutedFeatureSelector(route: route),
            transaction: ScriptedSelectedFeatureAuthoring()
        )
        _ = try await selection.selectAndAuthor(context)

        let req = try #require(capturingDispatch.requests.first)
        #expect(req.pass == .selection)
        let prov = try #require(req.provenance)
        #expect(prov.family == .selection)
        #expect(prov.routeTry == 1)
        #expect(prov.featureIssueID == nil)

        let event = try #require(try journal.events(ofType: .promptCaptureRequested).first?.event)
        guard case .promptCaptureRequested(
            let selID, let selPass, let selCardID, let selIssueID, let selAttemptID, let selRound, let selOrdinal
        ) = event else {
            Issue.record(Comment(rawValue: "expected .promptCaptureRequested for selection"))
            return
        }
        #expect(selID == prov.recordID)
        #expect(selPass == .selection)
        #expect(selCardID == nil)
        #expect(selIssueID == nil)
        #expect(selAttemptID == nil)
        #expect(selRound == nil)
        #expect(selOrdinal == 1)
    }

    @Test("AuthoringRoute.run dispatches breakdown, journaling PromptCaptureRequested with matching provenance")
    func authoringBreakdownJournalsPromptCaptureRequested() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBuildActBoards()
        let context = try makeSelectionContext(journal, repositories: selectionRepositories(), boards: boards).context

        let primary = Route(cli: "claude", model: "opus", effort: "high")!
        let table = RoutingTable(entries: [RoutingEntry(kind: .authoring, route: primary)])
        let capturingDispatch = CapturingAuthoringDispatch([
            .breakdown: try DispatchResult.breakdown(BreakdownResult(outcome: .drafted(authoringBreakdown())))
        ])
        let route = AuthoringRoute(resolver: RouteResolver(table: table) { _ in .offered }, dispatch: capturingDispatch)

        let transaction = AuthoringTransaction(
            drafting: RoutedFeatureBreakdown(route: route), citations: FakeCitationResolver(),
            transcribing: FakeContractTranscriber(), provenance: FakeProvenanceTester()
        )
        _ = try await transaction.author(authoringSelection(), context: context)

        let req = try #require(capturingDispatch.requests.first)
        #expect(req.pass == .breakdown)
        let prov = try #require(req.provenance)
        #expect(prov.family == .breakdown)
        #expect(prov.routeTry == 1)
        let expectedFeatureID = try authoringSelection().name.rawValue
        #expect(prov.featureIssueID == nil)
        #expect(prov.featureName == expectedFeatureID)

        let event = try #require(try journal.events(ofType: .promptCaptureRequested).first?.event)
        guard case .promptCaptureRequested(
            let bdID, let bdPass, let bdCardID, let bdIssueID, let bdAttemptID, let bdRound, let bdOrdinal
        ) = event else {
            Issue.record(Comment(rawValue: "expected .promptCaptureRequested for breakdown"))
            return
        }
        #expect(bdID == prov.recordID)
        #expect(bdPass == .breakdown)
        #expect(bdCardID == nil)
        // The Feature Issue does not exist yet: the Feature's name is no `issue_id`, it rides on the provenance.
        #expect(bdIssueID == nil)
        #expect(bdAttemptID == nil)
        #expect(bdRound == nil)
        #expect(bdOrdinal == 1)
    }

    @Test("FeatureVerification dispatches verifier, journaling PromptCaptureRequested with matching provenance")
    func featureVerificationJournalsPromptCaptureRequested() async throws {
        let world = try await VerificationWorld()
        try world.addClause(issue: "BACK-1", cid: "c1")
        try world.addAttempt(card: "BACK-1", route: routeWriter)
        let dispatch = ScriptedVerifierDispatch([routeOther: .judgeAll()])
        let resolver = verificationResolver(primary: routeWriter, fallbacks: [routeOther])

        _ = try await world.verification(resolver: resolver, dispatch: dispatch)
            .verify(world.featureContext)

        let req = try #require(dispatch.requests.first)
        #expect(req.pass == .verifier)
        let prov = try #require(req.provenance)
        #expect(prov.family == .verifier)
        #expect(prov.routeTry == 1)
        #expect(prov.featureIssueID == world.featureContext.feature.issueID)

        let events = try world.journal.events(ofType: .promptCaptureRequested)
        #expect(events.count == 1)
        guard case .promptCaptureRequested(
            let id, let pass, let cardID, let issueID, let attemptID, let round, let ordinal
        ) = events[0].event else {
            Issue.record(Comment(rawValue: "expected .promptCaptureRequested for verifier"))
            return
        }
        #expect(id == prov.recordID)
        #expect(pass == .verifier)
        #expect(cardID == nil)
        #expect(issueID == world.featureContext.feature.issueID)
        #expect(attemptID == nil)
        #expect(round == nil)
        #expect(ordinal == 1)
    }

    @Test("A real authoring walk journals each try's capture before its rejected/dispatched event, and they pair")
    func authoringWalkPairsEachTryWithItsOwnCapture() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBuildActBoards()
        let context = try makeSelectionContext(journal, repositories: selectionRepositories(), boards: boards).context
        let first = Route(cli: "claude", model: "opus", effort: "high")!
        let second = Route(cli: "codex", model: "sol", effort: "high")!
        let table = RoutingTable(entries: [RoutingEntry(kind: .authoring, route: first, fallbacks: [second])])
        let dispatch = RefusingFirstDispatch(.selection(SelectionResult(outcome: .noSelectableFeature)))
        let route = AuthoringRoute(resolver: RouteResolver(table: table) { _ in .offered }, dispatch: dispatch)

        _ = try await FeatureSelection(
            selector: RoutedFeatureSelector(route: route), transaction: ScriptedSelectedFeatureAuthoring()
        ).selectAndAuthor(context)

        let records = try journal.events(runID: context.runID, ofTypes: [
            .promptCaptureRequested, .authoringDispatched, .authoringRouteRejected
        ])
        let captureIDs = records.compactMap { record -> String? in
            if case .promptCaptureRequested(let recordID, _, _, _, _, _, _) = record.event { recordID } else { nil }
        }
        #expect(captureIDs.count == 2)
        // The append order the pairing relies on: capture, rejection, capture, dispatched.
        #expect(records.map(\.type) == [
            .promptCaptureRequested, .authoringRouteRejected, .promptCaptureRequested, .authoringDispatched
        ])
        let paired = PromptCapturePairing.recordIDs(in: records)
        #expect(paired[records[1].id] == captureIDs[0])
        #expect(paired[records[3].id] == captureIDs[1])
    }

    // A rehearsal Night's dispatch writes no prompt record, so no pass may journal a capture request for one.

    @Test("A rehearsal dispatch records no prompt; an agent CLI dispatch does")
    func onlyRehearsalRecordsNoPrompts() {
        #expect(!RehearsalDispatch().recordsPrompts)
        #expect(CapturingAuthoringDispatch([:]).recordsPrompts)
    }

    @Test("A rehearsal CardRun journals no PromptCaptureRequested for any of its passes")
    func rehearsalCardRunJournalsNoPromptCapture() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let world = try await makeCardRunWorld(journal: journal)
        let dispatch = RehearsalDispatch()

        try await makeCardRun(dispatch: dispatch).run("BACK-1", in: world)

        #expect(dispatch.answered.contains { $0.pass == .worker })
        #expect(try journal.events(ofType: .promptCaptureRequested).isEmpty)
    }

    @Test("A rehearsal authoring pass journals no PromptCaptureRequested")
    func rehearsalAuthoringJournalsNoPromptCapture() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBuildActBoards()
        let context = try makeSelectionContext(journal, repositories: selectionRepositories(), boards: boards).context
        let primary = Route(cli: "claude", model: "opus", effort: "high")!
        let table = RoutingTable(entries: [RoutingEntry(kind: .authoring, route: primary)])
        let dispatch = RehearsalDispatch()
        let route = AuthoringRoute(resolver: RouteResolver(table: table) { _ in .offered }, dispatch: dispatch)

        _ = try await FeatureSelection(
            selector: RoutedFeatureSelector(route: route), transaction: ScriptedSelectedFeatureAuthoring()
        ).selectAndAuthor(context)

        #expect(dispatch.answered.map(\.pass) == [.selection])
        #expect(dispatch.answered.allSatisfy { $0.provenance == nil })
        #expect(try journal.events(ofType: .promptCaptureRequested).isEmpty)
    }

    @Test("A rehearsal verifier pass journals no PromptCaptureRequested")
    func rehearsalVerifierJournalsNoPromptCapture() async throws {
        let world = try await VerificationWorld()
        try world.addClause(issue: "BACK-1", cid: "c1")
        try world.addAttempt(card: "BACK-1", route: routeWriter)
        let dispatch = RehearsalDispatch()
        let resolver = verificationResolver(primary: routeWriter, fallbacks: [routeOther])

        _ = try await world.verification(resolver: resolver, dispatch: dispatch).verify(world.featureContext)

        #expect(dispatch.answered.map(\.pass) == [.verifier])
        #expect(try world.journal.events(ofType: .promptCaptureRequested).isEmpty)
    }

    @Test("ReportingDispatchPromptRecorder forwards capture and markLaunch, writing to stderr on unavailable")
    func reportingRecorderBehavior() {
        final class MockStore: DispatchPromptRecording, @unchecked Sendable {
            var result: DispatchPromptCapture = .unavailable(cause: "no space")
            var marked: [(DispatchLaunch, DispatchPromptRecord)] = []
            func capture(_ record: DispatchPromptRecord) -> DispatchPromptCapture { result }
            func markLaunch(_ launch: DispatchLaunch, of record: DispatchPromptRecord) -> Bool {
                marked.append((launch, record))
                return true
            }
        }

        let store = MockStore()
        let recorder = ReportingDispatchPromptRecorder(store: store)
        let provenance = DispatchProvenance(
            recordID: "rec-test", family: .worker, projectID: "proj-1", runID: "run-1", nightID: 1
        )
        let record = DispatchPromptRecord(
            provenance: provenance, route: "claude/opus/high", pass: .worker, dispatchedAt: Date(),
            defaultVersion: 1, session: .new, instruction: "hi", outputSchema: nil
        )

        let captureResult = recorder.capture(record)
        #expect(captureResult == .unavailable(cause: "no space"))

        let markResult = recorder.markLaunch(.launched, of: record)
        #expect(markResult == true)
        #expect(store.marked.count == 1)
        #expect(store.marked[0].0 == .launched)
    }
}

private final class CapturingAuthoringDispatch: AgentDispatch, Sendable {
    private let results: [RunPass: DispatchResult]
    private let log = Mutex<[AgentDispatchRequest]>([])

    init(_ results: [RunPass: DispatchResult]) {
        self.results = results
    }

    var requests: [AgentDispatchRequest] { log.withLock { $0 } }

    func dispatch(_ request: AgentDispatchRequest) async throws -> AgentDispatchReport {
        log.withLock { $0.append(request) }
        guard let result = results[request.pass] else {
            throw AgentDispatchRefusal(reason: "unscripted pass \(request.pass)")
        }
        return AgentDispatchReport(outcome: .completed(result))
    }
}

/// Refuses its first dispatch (the Route is unavailable), then answers every later one with `result`.
private final class RefusingFirstDispatch: AgentDispatch, Sendable {
    private let result: DispatchResult
    private let calls = Mutex<Int>(0)

    init(_ result: DispatchResult) {
        self.result = result
    }

    func dispatch(_ request: AgentDispatchRequest) async throws -> AgentDispatchReport {
        let call = calls.withLock { count -> Int in
            count += 1
            return count
        }
        if call == 1 { throw AgentDispatchRefusal(reason: "first Route unavailable") }
        return AgentDispatchReport(outcome: .completed(result))
    }
}
