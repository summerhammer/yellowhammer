import Domain
import Foundation
import Journal

extension CardDetail {
    /// Reads one Card's detail from its own Project's Journal.
    ///
    /// The Journal is found by `project` alone, opened read-only, read in one transaction and closed
    /// before this returns, so no connection outlives the read ("Nothing resident") and nothing of a
    /// sibling Project's can appear in it (R20; ADR-002). The read never creates or migrates a Journal,
    /// and an Act writing the same Journal meanwhile is never blocked for longer than that one read.
    ///
    /// It may wait for the Journal's busy timeout while an Act holds the write lock, so call it off the
    /// main actor.
    public static func read(issueID: String, project: ProjectID, configurationDirectory: URL) -> CardDetailRead {
        let fileURL = JournalStore.defaultFileURL(configurationDirectory: configurationDirectory, id: project)
        do {
            let journal = try JournalStore.openReadOnly(at: fileURL, projectID: project)
            guard let detail = try read(from: journal, issueID: issueID) else { return .noSuchCard }
            return .detail(detail)
        } catch JournalError.missing {
            return .journalMissing
        } catch {
            return .journalFailure("\(error)")
        }
    }

    /// Fills one Card's detail from `journal`. Nil when the Journal records no Card with `issueID`.
    ///
    /// Like ``PulseSnapshot/read(from:status:)``, the read is HANDED a store and never opens one, so every
    /// value comes from this one store. It only reads.
    public static func read(from journal: JournalStore, issueID: String) throws -> CardDetail? {
        try journal.cardAccount(issueID: issueID).map(CardDetail.init(account:))
    }

    private init(account: CardAccount) {
        let card = account.card
        self.init(
            id: card.issueID,
            title: card.displayTitle,
            repo: card.repository,
            kind: card.kind,
            state: card.state,
            waitingReason: card.state == .waitingOnYou ? card.waitingReason?.rawValue : nil,
            blockReason: card.state == .blocked ? card.blockReason.flatMap { BlockReason(rawValue: $0) } : nil,
            budgetEpoch: card.budgetEpoch,
            routesTried: account.history.routesTried.map(\.description),
            excludedRoutes: account.history.excludedRoutes.map(\.description),
            attempts: account.history.attempts.map { attempt in
                Attempt(record: attempt, checkRuns: account.checkRuns(attemptID: attempt.id))
            }
        )
    }
}

extension CardDetail.Attempt {
    fileprivate init(record: AttemptRecord, checkRuns: [CheckRunRecord]) {
        self.init(
            id: String(record.id),
            route: record.route.description,
            routeSource: record.routeSource,
            overridePin: record.overridePin,
            startedAt: record.startedAt,
            endedAt: record.endedAt,
            result: record.result,
            classification: record.classification,
            consumedHow: record.consumedHow,
            preservedRef: record.preservedRef,
            preservedCommit: record.preservedCommit,
            checkDeclaredNone: record.checkDeclaredNone,
            rounds: record.rounds.map { round in
                CardDetail.Round(
                    id: String(round.id),
                    lens: round.lens,
                    verdict: round.verdict,
                    requestedChanges: round.requestedChanges,
                    judgedCommit: round.judgedCommit
                )
            },
            checkRuns: checkRuns.map { run in
                CardDetail.CheckRun(
                    id: String(run.eventID),
                    result: run.result,
                    exitStatus: run.exitStatus,
                    output: run.output,
                    occurredAt: run.occurredAt
                )
            }
        )
    }
}
