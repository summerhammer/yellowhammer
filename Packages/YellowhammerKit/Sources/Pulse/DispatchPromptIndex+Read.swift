import Config
import Domain
import Foundation
import Journal

struct AttemptReadContext {
    let journal: JournalStore
    let store: DispatchPromptStore
    let projectID: ProjectID
    let cardID: Int64
    let attemptID: Int64
    let asOf: Date
}

extension DispatchPromptIndex {
    /// Reads dispatch prompt index for one Attempt or Night from its own Project's Journal and prompt store.
    public static func read(
        journal: JournalStore?,
        store: DispatchPromptStore,
        projectID: ProjectID?,
        scope: Scope,
        asOf: Date = Date()
    ) throws -> DispatchPromptIndex {
        switch scope {
        case .attempt(let cardID, let attemptID):
            guard let journal, let projectID else {
                throw JournalError.missing(path: "journal missing")
            }
            let context = AttemptReadContext(
                journal: journal,
                store: store,
                projectID: projectID,
                cardID: cardID,
                attemptID: attemptID,
                asOf: asOf
            )
            return try readAttempt(context: context)
        case .night(let nightID):
            guard let journal, let projectID else {
                throw JournalError.missing(path: "journal missing")
            }
            let context = NightReadContext(
                journal: journal,
                store: store,
                projectID: projectID,
                nightID: nightID,
                asOf: asOf
            )
            return try readNight(context: context)
        case .machine(let runID, let cli):
            let runs = machine(store: store, cli: cli, asOf: asOf)
            if runs.isEmpty {
                return DispatchPromptIndex(
                    projectID: nil,
                    scope: scope,
                    emptyState: .noDiagnosticDispatchesRecorded,
                    items: []
                )
            }
            if let runID {
                if let run = runs.first(where: { $0.runID == runID }) {
                    return run.index
                }
                return DispatchPromptIndex(
                    projectID: nil,
                    scope: scope,
                    emptyState: .noDiagnosticDispatchesRecorded,
                    items: []
                )
            }
            return runs[0].index
        }
    }

    /// Reads prompt index from disk using the configuration directory.
    public static func read(
        configurationDirectory: URL,
        projectID: ProjectID,
        scope: Scope,
        asOf: Date = Date()
    ) -> DispatchPromptIndexRead {
        if case .machine = scope {
            return read(configurationDirectory: configurationDirectory, scope: scope, asOf: asOf)
        }
        let fileURL = JournalStore.defaultFileURL(configurationDirectory: configurationDirectory, id: projectID)
        do {
            let journal = try JournalStore.openReadOnly(at: fileURL, projectID: projectID)
            let store = DispatchPromptStore(
                rootDirectory: DispatchPromptStore.rootDirectory(configurationDirectory: configurationDirectory),
                now: { asOf }
            )
            let index = try read(
                journal: journal,
                store: store,
                projectID: projectID,
                scope: scope,
                asOf: asOf
            )
            return .index(index)
        } catch JournalError.missing {
            return .journalMissing
        } catch {
            return .journalFailure("\(error)")
        }
    }

    /// Reads machine-scope prompt index from disk without a Project.
    public static func read(
        configurationDirectory: URL,
        scope: Scope,
        asOf: Date = Date()
    ) -> DispatchPromptIndexRead {
        let store = DispatchPromptStore(
            rootDirectory: DispatchPromptStore.rootDirectory(configurationDirectory: configurationDirectory),
            now: { asOf }
        )
        do {
            let index = try read(
                journal: nil,
                store: store,
                projectID: nil,
                scope: scope,
                asOf: asOf
            )
            return .index(index)
        } catch {
            return .journalFailure("\(error)")
        }
    }

    /// Resolves card row from issue id and reads prompt index for one Attempt.
    public static func read(
        configurationDirectory: URL,
        projectID: ProjectID,
        issueID: String,
        attemptID: Int64,
        asOf: Date = Date()
    ) -> DispatchPromptIndexRead {
        let fileURL = JournalStore.defaultFileURL(configurationDirectory: configurationDirectory, id: projectID)
        do {
            let journal = try JournalStore.openReadOnly(at: fileURL, projectID: projectID)
            guard let card = try journal.card(issueID: issueID) else {
                return .noSuchCard
            }
            let store = DispatchPromptStore(
                rootDirectory: DispatchPromptStore.rootDirectory(configurationDirectory: configurationDirectory),
                now: { asOf }
            )
            let index = try read(
                journal: journal,
                store: store,
                projectID: projectID,
                scope: .attempt(cardID: card.id, attemptID: attemptID),
                asOf: asOf
            )
            return .index(index)
        } catch JournalError.missing {
            return .journalMissing
        } catch {
            return .journalFailure("\(error)")
        }
    }

    // MARK: - Private Attempt Read

    private static func readAttempt(context: AttemptReadContext) throws -> DispatchPromptIndex {
        let allEvents = try context.journal.events(ofType: nil)
        let attemptHistory = try? context.journal.attemptHistory(cardID: context.cardID)
        let attemptRecord = attemptHistory?.attempts.first(where: { $0.id == context.attemptID })
        let fallbackRoute = attemptRecord?.route.description ?? ""

        var items: [DispatchPromptItem] = []
        var hasEvidence = false

        for eventRecord in allEvents {
            if let item = processAttemptEvent(
                eventRecord: eventRecord,
                fallbackRoute: fallbackRoute,
                workerCount: items.count { $0.pass == .worker },
                context: context
            ) {
                hasEvidence = true
                items.append(item)
            } else if isAttemptDispatchEvidence(
                eventRecord.event,
                cardID: context.cardID,
                attemptID: context.attemptID
            ) {
                hasEvidence = true
            }
        }

        if items.isEmpty {
            let emptyState: EmptyState = hasEvidence ? .legacy : .noDispatchesYet
            return DispatchPromptIndex(
                projectID: context.projectID,
                scope: .attempt(cardID: context.cardID, attemptID: context.attemptID),
                emptyState: emptyState,
                items: []
            )
        }

        return DispatchPromptIndex(
            projectID: context.projectID,
            scope: .attempt(cardID: context.cardID, attemptID: context.attemptID),
            emptyState: nil,
            items: items
        )
    }

    private static func isAttemptDispatchEvidence(
        _ event: JournalEvent,
        cardID: Int64,
        attemptID: Int64
    ) -> Bool {
        switch event {
        case .agentCLIProcessSpawned(let cID, _, let aID, _, _):
            cID == cardID && aID == attemptID
        case .rehearsalFixtureAnswered(let cID, _, let aID, _, _):
            cID == cardID && aID == attemptID
        case .promptCaptureRequested(_, _, let cID, _, let aID, _, _):
            cID == cardID && aID == attemptID
        default:
            false
        }
    }

    private static func processAttemptEvent(
        eventRecord: JournalEventRecord,
        fallbackRoute: String,
        workerCount: Int,
        context: AttemptReadContext
    ) -> DispatchPromptItem? {
        switch eventRecord.event {
        case .promptCaptureRequested(
            let recordID, let pass, let evtCardID, let issueID, let evtAttemptID, let round, let ordinal
        ):
            guard evtCardID == context.cardID && evtAttemptID == context.attemptID else { return nil }
            let itemContext = PromptItemBuildContext(
                recordID: recordID,
                pass: pass,
                round: round,
                ordinal: ordinal,
                issueID: issueID,
                cardID: context.cardID,
                attemptID: context.attemptID,
                nightID: eventRecord.nightID,
                fallbackRoute: fallbackRoute,
                eventTime: eventRecord.occurredAt
            )
            return makeItem(
                context: itemContext,
                store: context.store,
                projectID: context.projectID,
                asOf: context.asOf
            )

        case .rehearsalFixtureAnswered(let evtCardID, _, let evtAttemptID, let pass, let fixture):
            guard evtCardID == context.cardID && evtAttemptID == context.attemptID else { return nil }
            let round = pass == .worker ? (workerCount + 1) : nil
            let params = AttemptRehearsalParams(
                pass: pass,
                fixture: fixture,
                fallbackRoute: fallbackRoute,
                round: round
            )
            return makeAttemptRehearsalItem(
                eventRecord: eventRecord,
                params: params,
                context: context
            )

        default:
            return nil
        }
    }

    private struct AttemptRehearsalParams {
        let pass: RunPass
        let fixture: String
        let fallbackRoute: String
        let round: Int?
    }

    private static func makeAttemptRehearsalItem(
        eventRecord: JournalEventRecord,
        params: AttemptRehearsalParams,
        context: AttemptReadContext
    ) -> DispatchPromptItem {
        let isResumed = params.pass == .worker && (params.round ?? 1) > 1
        return DispatchPromptItem(
            id: "rehearsal-\(eventRecord.id)",
            recordID: nil,
            pass: params.pass,
            round: params.round,
            routeTry: nil,
            route: params.fallbackRoute.isEmpty ? "rehearsal" : params.fallbackRoute,
            time: eventRecord.occurredAt,
            session: isResumed ? .resumed : .new,
            state: .rehearsal(fixture: params.fixture),
            family: PromptFamily(pass: params.pass),
            projectID: context.projectID,
            defaultVersion: nil,
            projectInstructions: .absent,
            launch: nil,
            nightID: eventRecord.nightID,
            featureIssueID: nil,
            workCardIssueID: nil,
            cardID: context.cardID,
            attemptID: context.attemptID,
            instruction: nil,
            outputSchema: nil
        )
    }
}
