import Domain
import Foundation
import Journal

/// What one Card run holds while it runs: the Card, where it runs, and the board projection it writes
/// through. Rebuilt from the Journal and the Delta Read on every run — nothing here outlives it.
struct CardRunFrame: Sendable {
    var card: CardRecord
    let context: BuildActContext
    let readiness: CardReadiness
    /// This Card's Repo Lane, as derived for this build Act (authored order, all states, possibly
    /// stale by the time a later pass reads it — the Journal is re-read for current state when a
    /// hole is named). Threaded through so the authoring-invariant violation report (graph-execution/
    /// handle-a-block-mid-graph, P8.9) can name an earlier Blocked or Waiting-on-You Card in the same
    /// lane as the likely hole.
    let lane: RepoLane
    let repository: Repo?
    let check: Check
    let worktree: WorktreeRecord
    let branch: FeatureBranch
    let projection: BoardStateProjection?
    let instructionCard: InstructionCard
    /// The Card's board object (the Delta Read's copy, else one board read) and its Feature Issue's:
    /// they supply the human keys and the Feature title for the worker's commit message. Nil with no
    /// Board, or when the board did not return them.
    let cardObject: BoardObject?
    let featureObject: BoardObject?
    /// Set once the Route is resolved and the Attempt recorded.
    var attempt: AttemptRecord?
    var route: Route?
    /// The prior Attempt's preserved work, handed to a retry as context only, never as a starting
    /// tree (OQ60): set by the reset sequence, merged into every pass instruction of the new Attempt.
    /// A second source seeds it: a resumed Card whose latest Attempt ended `question` carries that
    /// Attempt's preserved work into the run's first Attempt (OQ106), set in `prepare`.
    var wipContext: WIPContext?
    /// The Card's latest recorded question, with every Operator reply this Journal has recorded as an
    /// answer to it (roadmap P11.2): set once in ``prepare(card:in:context:readiness:)`` from the
    /// Journal alone, and merged into every pass instruction of every Attempt of this run, like
    /// `wipContext`. Nil when the latest question has no recorded answer yet — a newer question with no
    /// answers carries nothing, even if an older one did.
    var answeredQuestion: AnsweredQuestion?
    /// Every reply banked against this Card (roadmap P11.5), in Journal order, set once in
    /// ``prepare(card:in:context:readiness:)`` and merged into every pass instruction of every Attempt
    /// of this run, like `answeredQuestion`. A banked reply is excluded from `answeredQuestion.replies`
    /// so each reply appears once, carrying its own dated, unverified nature.
    var bankedReplies: [BankedReply] = []

    var journal: JournalStore { context.act.journal }

    /// Throws ``JournalError/cardLeaseLost(cardID:runID:holder:)`` unless this run still holds the Card's
    /// Lease. Called before every Journal or board write that records an outcome: sleep is more dangerous
    /// than a crash.
    func revalidateLease() throws {
        _ = try journal.revalidateCardLease(cardID: card.id, runID: context.act.runID)
    }

    func record(_ step: CardRunStep, detail: String? = nil) throws {
        try journal.append(
            .cardRunStep(cardID: card.id, issueID: card.issueID, step: step, detail: detail),
            act: context.act.act, runID: context.act.runID, nightID: context.act.night.id
        )
    }

    /// Records whether a pass that dispatched successfully actually spawned an agent CLI process, or a
    /// rehearsal Night's fixture answered in its place (system-overview, Environment Differences, P8.11).
    func recordDispatchOrigin(_ origin: AgentDispatchOrigin, attemptID: Int64, pass: RunPass, cli: String) throws {
        switch origin {
        case .agentCLIProcess:
            try journal.append(
                .agentCLIProcessSpawned(
                    cardID: card.id, issueID: card.issueID, attemptID: attemptID, pass: pass, cli: cli
                ),
                act: context.act.act, runID: context.act.runID, nightID: context.act.night.id
            )
        case .rehearsalFixture(let fixture):
            try journal.append(
                .rehearsalFixtureAnswered(
                    cardID: card.id, issueID: card.issueID, attemptID: attemptID, pass: pass, fixture: fixture
                ),
                act: context.act.act, runID: context.act.runID, nightID: context.act.night.id
            )
        }
    }

    /// Transitions the Card through the board projection, or on the Journal alone when the invocation has
    /// no Board (a later Act reposts it).
    func transition(_ transition: CardTransition) async throws {
        try revalidateLease()
        let current = try journal.card(id: card.id)
        if let projection {
            _ = try await projection.transition(card: current, to: transition)
        } else {
            try journal.transitionCard(
                cardID: card.id, to: transition.state, waitingReason: transition.waitingReason,
                blockReason: transition.blockReason, runID: context.act.runID, act: context.act.act,
                nightID: context.act.night.id
            )
        }
    }

    /// The Override the Operator pinned on this Card's board object, read from the Delta Read's copy of it;
    /// none when the Delta Read did not see the Card change or this invocation has no Board.
    func override() async throws -> Override? {
        guard let object = changedObject, let board = context.act.board, let projection else {
            return nil
        }
        let labels = try await board.provisioning.labels(team: projection.scope.team)
        return OverrideLabels(labels: labels).override(on: object)
    }

    /// The Card's board object, when this Card is among the Delta Read's changes.
    var changedObject: BoardObject? {
        context.deltaRead?.cardChanges.first { $0.card.id == card.id }?.object
    }
}

extension CardRun {
    /// Gathers what the run needs before anything is spent: an Attempt is never recorded for a Card that
    /// cannot be dispatched for want of a Worktree, a Feature Branch or a declared Check.
    func prepare(
        card: CardRecord, in lane: RepoLane, context: BuildActContext, readiness: CardReadiness
    ) async throws -> CardRunFrame {
        let journal = context.act.journal
        guard let worktree = try journal.heldWorktree(featureID: context.feature.id, repository: card.repository) else {
            throw CardRunError.worktreeMissing(featureID: context.feature.id, repository: card.repository)
        }
        guard let branch = try journal.resolvedFeatureBranch(feature: context.feature, repository: card.repository)
        else {
            throw BuildActError.featureBranchUnrecorded(featureID: context.feature.id)
        }
        guard let check = checks[card.repository] else {
            throw CardRunError.checkUnknown(repository: card.repository)
        }

        var projection: BoardStateProjection?
        if let board = context.act.board, let outbox = context.act.outbox {
            let scope = try await BoardStateScope.resolve(using: board.provisioning)
            projection = BoardStateProjection(journal: journal, outbox: outbox, scope: scope)
        }

        // The Delta Read's board object carries the freshest title only when the Card changed since the
        // last read; otherwise the Journal's own recorded title is used, falling back to the issue id
        // for a Card the Journal has never reconciled a title for (issue #161; spec:
        // landing/announce-a-partial-landing).
        let object = context.deltaRead?.cardChanges.first { $0.card.id == card.id }?.object
        var cardObject = object
        var featureObject: BoardObject?
        if let board = context.act.board {
            let wanted: Set<String> = object == nil
                ? [card.issueID, context.feature.issueID] : [context.feature.issueID]
            let found = await BoardObjectLookup.find(ids: wanted, board: board)
            cardObject = object ?? found[card.issueID]
            featureObject = found[context.feature.issueID]
        }
        var frame = CardRunFrame(
            card: card, context: context, readiness: readiness, lane: lane,
            repository: context.act.repositories?.workingRepo(named: card.repository), check: check,
            worktree: worktree, branch: branch, projection: projection,
            instructionCard: InstructionCard(
                key: card.issueID, title: object?.title ?? card.title ?? card.issueID,
                description: object?.description
            ),
            cardObject: cardObject, featureObject: featureObject
        )
        let banked = try journal.bankedCardReplies(cardID: card.id)
        let bankedCommentIDs = Set(banked.map { $0.reply.commentID })
        frame.answeredQuestion = try Self.answeredQuestion(
            cardID: card.id, journal: journal, excluding: bankedCommentIDs
        )
        frame.bankedReplies = try banked.map { try Self.bankedReply($0, journal: journal) }
        frame.wipContext = try Self.resumedWIPContext(cardID: card.id, journal: journal)
        return frame
    }

    /// A resumed Card is a new Attempt from `last_known_good_commit`, with the work its question Attempt
    /// preserved handed over as context, not a starting tree (Landing Edge Cases Ruling 2026-10-01,
    /// OQ106): the same ``WIPContext`` shape an in-run retry gets. Only the Card's latest Attempt counts,
    /// and only when it ended `question` and carries a preserved ref; nothing else here is resumption.
    private static func resumedWIPContext(cardID: Int64, journal: JournalStore) throws -> WIPContext? {
        guard let latest = try journal.attemptHistory(cardID: cardID).attempts.last,
            latest.result == AttemptOutcome.question.rawValue,
            let ref = latest.preservedRef, let commit = latest.preservedCommit
        else { return nil }
        return WIPContext(commit: commit, note: "preserved at \(ref)")
    }

    /// The Card's latest question, with every recorded answer to it that is not itself banked (roadmap
    /// P11.2, P11.5): nil when the latest question has none recorded yet, so a resumed run never carries
    /// a question the Operator has not actually answered. A banked reply appears only in
    /// ``bankedReplies``, never twice.
    private static func answeredQuestion(
        cardID: Int64, journal: JournalStore, excluding bankedCommentIDs: Set<String>
    ) throws -> AnsweredQuestion? {
        guard let question = try journal.latestCardQuestion(cardID: cardID) else { return nil }
        let answers = try journal.cardReplies(questionID: question.id, disposition: .answer)
            .filter { !bankedCommentIDs.contains($0.commentID) }
        guard !answers.isEmpty, let night = try journal.night(id: question.nightID) else { return nil }
        return AnsweredQuestion(
            question: question.question, askedOn: night.nightStart,
            replies: answers.map { OperatorReply(body: $0.body, repliedAt: $0.commentedAt, commentID: $0.commentID) }
        )
    }

    /// One banked reply, with its Night and every touched repository's mainline commit as of the Night
    /// it was banked (roadmap P11.5).
    private static func bankedReply(_ banked: BankedCardReply, journal: JournalStore) throws -> BankedReply {
        guard let night = try journal.night(id: banked.nightID) else {
            throw JournalError.nightUnknown(id: banked.nightID)
        }
        var commits: [String: String] = [:]
        for stamp in banked.stamps {
            if let commit = stamp.commit { commits[stamp.repository] = commit }
        }
        return BankedReply(
            body: banked.reply.body, night: night.nightStart, mainlineCommits: commits,
            commentID: banked.reply.commentID
        )
    }
}
