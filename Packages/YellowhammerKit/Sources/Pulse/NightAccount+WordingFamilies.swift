import Domain
import Foundation
import Journal

// The families ``NightWording`` words, one function each. A function returns nil for an event outside its
// family, so the next family is tried. Detail lines carry only what the engine recorded about itself.

extension NightWording {
    /// An Act's own lifecycle.
    func lifecycle(_ event: JournalEvent) -> NightWords? {
        switch event {
        case .actStarted:
            NightWords(headline: "\(actName) started")
        case .actEnded:
            NightWords(headline: "\(actName) ended")
        case .actIdle(let reason):
            NightWords(headline: "\(actName) idle — nothing to do", detail: NightAccount.words(idleReason: reason))
        case .actIncomplete(let reason):
            NightWords(headline: "\(actName) could not complete", detail: reason)
        case .actStoodDown(let holder):
            NightWords(
                headline: "\(actName) stood down — another run holds the Project",
                detail: "Held by the \(holder.act.rawValue) Act"
            )
        default:
            nil
        }
    }

    /// The Night's own events, and the Linear halts and reach.
    func night(_ event: JournalEvent) -> NightWords? {
        switch event {
        case .linearAuthorizationHalted:
            NightWords(headline: "Halted — Linear refused the Board Connection")
        case .linearUnreachableHalted:
            NightWords(headline: "Halted — Linear was unreachable")
        case .linearReached:
            NightWords(headline: "Reached Linear")
        case .nightOpened:
            NightWords(headline: "Night opened")
        case .nightClosed(let reason):
            NightWords(headline: "Night closed", detail: NightAccount.words(closeReason: reason))
        case .nightOpenedAndDied(_, let nightStart):
            NightWords(
                headline: "The previous Night opened and died",
                detail: "The Night of \(nightStart) was left open with no completion"
            )
        case .absentNightDetected(let nightStart):
            NightWords(headline: "A Night never opened", detail: "No Night opened on \(nightStart)")
        default:
            nil
        }
    }

    /// Leases, mainline, notifications and the Board's own limits.
    func infrastructure(_ event: JournalEvent) -> NightWords? {
        switch event {
        case .leaseReclaimed(_, let previousAct, _):
            NightWords(headline: "Reclaimed an expired Lease", detail: "Left by a \(previousAct.rawValue) Act run")
        case .cardLeaseReclaimed(let cardID, _, _):
            NightWords(headline: "Reclaimed an expired Lease on \(card(cardID))")
        case .mainlineFetchFailed(let repository, let reason):
            NightWords(headline: "Could not fetch mainline of \(repository)", detail: reason)
        case .notificationDeliveryFailed(let notification, let reason):
            NightWords(headline: "A notification was not delivered", detail: "\(notification): \(reason)")
        case .boardWriteFailed(_, let operation, _, let reason):
            NightWords(headline: "Linear was not updated", detail: "\(operation): \(reason)")
        case .managedBlockOverBudget(let issueID, let length, let budget):
            NightWords(
                headline: "A description was not rewritten — it would be over its budget",
                detail: "\(issueID): \(length) against a budget of \(budget)"
            )
        case .rateBudgetExhausted(let degradation, _):
            NightWords(headline: "Linear's request budget ran out", detail: degradation)
        case .boardScopeUnresolved(let steps):
            NightWords(headline: "Part of the Board's scope could not be resolved", detail: steps)
        case .worktreeNameCollision(let repository, let requested, let reported):
            NightWords(
                headline: "Orca ADE reported a different branch in \(repository)",
                detail: "Requested \(requested), reported \(reported)"
            )
        default:
            nil
        }
    }

    /// A Delta Read that stopped before its last page (the request cap) and moved no cursor.
    func incompleteRead(_ event: JournalEvent) -> NightWords? {
        guard case .deltaReadIncomplete(_, let reason) = event else { return nil }
        return NightWords(headline: "Not all of Linear's changes were read", detail: reason)
    }

    /// Repo Lanes, Attempts, Checks and Card states. A Check's output is never read.
    func cards(_ event: JournalEvent) -> NightWords? {
        switch event {
        case .repoLaneStarted(let repository, let cards):
            NightWords(headline: "Repo Lane \(repository) started", detail: count(cards, "Card"))
        case .repoLaneEnded(let repository, let cardsRun, let failure, let cardsSkipped):
            NightWords(
                headline: "Repo Lane \(repository) \(failure == nil ? "ended" : "failed")",
                detail: failure ?? "\(count(cardsRun, "Card")) run, \(cardsSkipped) skipped"
            )
        case .attemptEnded(let cardID, _, _, let route, let outcome, let routeExcluded):
            NightWords(
                headline: "\(card(cardID)): Attempt ended",
                detail: "\(outcome) on \(route.description)\(routeExcluded ? "; Route excluded" : "")"
            )
        case .checkRan(let cardID, _, _, let result, let exitStatus, _, _, _):
            NightWords(
                headline: "\(card(cardID)): \(checkWords(result))",
                detail: exitStatus.map { "Exit status \($0)" }
            )
        case .cardStateTransitioned(let cardID, _, let from, let to, let waitingReason, let blockReason):
            NightWords(
                headline: "\(card(cardID)) moved from \(from.rawValue) to \(to.rawValue)",
                detail: blockReason.map { "Block Reason: \($0.rawValue)" }
                    ?? waitingReason.map { "Waiting on You: \($0.rawValue)" }
            )
        case .readinessCheckFailed(let cardID, _, let failures):
            NightWords(
                headline: "\(card(cardID)): readiness check failed",
                detail: "\(failures.joined(separator: "; ")). Not dispatched, and no Attempt was spent."
            )
        case .waitingOnYouUnbacked(_, let cardID, let reason):
            NightWords(
                headline: "\(cardID.map(card) ?? "A Card"): in Waiting on You with no record behind it",
                detail: "\(reason). Not dispatched."
            )
        default:
            nil
        }
    }

    private func checkWords(_ result: CheckRunResult) -> String {
        switch result {
        case .passed: "Check passed"
        case .failed: "Check failed"
        case .declaredNone: "Check declared none — nothing ran"
        }
    }

    /// The author Act's outcomes. A Feature is named, never its reasoning.
    func authoring(_ event: JournalEvent) -> NightWords? {
        switch event {
        case .authoringNoWorkAvailable:
            NightWords(headline: "Nothing to author")
        case .authoringSkippedFeatureInFlight(let featureIssueID):
            NightWords(headline: "Authored nothing — a Feature is already in flight", detail: feature(featureIssueID))
        case .authoringSkippedUnmergedStackFull(let features, _):
            NightWords(
                headline: StackFullSkip.headline,
                detail: features.map { "\($0.identifier) in \($0.unmergedRepositories.joined(separator: ", "))" }
                    .joined(separator: "; ")
            )
        case .featureSelected(let payload):
            NightWords(headline: "Selected the Feature “\(payload.name)”")
        case .featureAuthored(let payload):
            NightWords(
                headline: "Authored the Feature “\(payload.name)”",
                detail: "\(feature(payload.featureIssueID)), \(count(payload.cardCount, "Card"))"
            )
        case .featureAuthoringFailed(let name, _, let reason):
            NightWords(headline: "Authoring the Feature “\(name)” failed", detail: reason)
        case .featureBreakdownRejected(let name, let reason):
            NightWords(headline: "Authoring the Feature “\(name)” failed: breakdown rejected", detail: reason)
        case .featureSelectionFailed(let reason):
            NightWords(headline: "Selecting a Feature failed", detail: reason)
        case .featureAuthoringHalted(let name, let reasonKind, let detail):
            NightWords(
                headline: "Authoring the Feature “\(name)” halted",
                detail: NightAccount.words(haltKind: reasonKind, detail: detail)
            )
        default:
            authoringDecision(event) ?? authoringWalk(event)
        }
    }

    private func authoringDecision(_ event: JournalEvent) -> NightWords? {
        switch event {
        case .authoringHaltOpened(let name, let kind, let detail),
             .authoringHaltRepeated(let name, let kind, let detail):
            NightWords(
                headline: "Authoring the Feature “\(name)” halted — Waiting on You",
                detail: NightAccount.words(haltKind: kind, detail: detail) + "; requires an Operator turn in Linear"
            )
        case .refusalOpened(let name, _, let clauses, _), .refusalRepeated(let name, _, let clauses, _):
            NightWords(
                headline: "Authoring the Feature “\(name)” refused — Waiting on You",
                detail: "Specification too thin to cite a Definition of Done. " + clauses
                    + " Requires an Operator turn in Linear."
            )
        default:
            nil
        }
    }

    /// One authoring Route's rejection in a walk, and a Work Card breaking an authoring invariant.
    private func authoringWalk(_ event: JournalEvent) -> NightWords? {
        switch event {
        case .authoringRouteRejected(let pass, let route, let ordinal, let cause, let reason):
            NightWords(
                headline: "\(route): \(cause.phrase) — \(DescriptionBudgetOverrun.oneLineReason(reason))",
                detail: "\(pass.rawValue) pass, Route \(ordinal) of the walk"
            )
        case .authoringInvariantBroken(_, _, let reason):
            NightWords(headline: "A Work Card broke an authoring invariant", detail: reason)
        default:
            nil
        }
    }

    /// The land Act's outcomes.
    func landing(_ event: JournalEvent) -> NightWords? {
        switch event {
        case .cycleLanded:
            NightWords(headline: "The Cycle landed")
        case .featureVerified(_, let met, let unmet, let unresolved, let notChecked):
            NightWords(
                headline: "The Feature was verified",
                detail: "\(met) met, \(unmet) unmet, \(unresolved) unresolved, \(notChecked) not checked"
            )
        case .featureReturned(_, let featureIssueID, let unmet, let unresolved, let notChecked):
            NightWords(
                headline: "The Feature \(feature(featureIssueID)) was returned to you",
                detail: "\(unmet) unmet, \(unresolved) unresolved, \(notChecked) not checked"
            )
        case .landStep(let step, let repository, let outcome, let detail):
            NightWords(
                headline: NightAccount.words(step: step, outcome: outcome, repository: repository), detail: detail
            )
        default:
            nil
        }
    }
}
