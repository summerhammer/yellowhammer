import Domain
import Foundation
import Journal

// How a Journal event reads in a Night's account (OQ158 ruling items 14 and 16).
//
// The Journal module's payloads stay internal, so this pattern-matches `JournalEvent` and words only the
// families that matter. Every other event reads as its type's name in plain words, with no detail.
//
// Nothing here renders agent output or model-authored free text: a Check's output tail, a Feature
// selection's reasoning, a question or reply, a review's requested changes and process output are never
// read. What is worded is what the engine recorded about itself — identifiers, repos, routes, states,
// counts, results and reasons.

extension NightAccount.Entry {
    /// The entry for one Journal event. `cardNames` maps a Card's Journal id to its display identifier;
    /// a Card it does not name reads as `Card <id>`. `featureNames` maps a Feature Issue's id to its display
    /// identifier; a Feature it does not name reads as the raw issue id.
    init(record: JournalEventRecord, cardNames: [Int64: String], featureNames: [String: String] = [:]) {
        let wording = NightWording(act: record.act, cardNames: cardNames, featureNames: featureNames)
        let words = wording.words(for: record.event)
        self.init(
            id: record.id,
            occurredAt: record.occurredAt,
            headline: words.headline,
            detail: words.detail,
            isProblem: NightAccount.isProblem(record),
            failedAct: NightAccount.isProblem(record) ? record.act : nil
        )
    }
}

extension NightAccount {
    /// The Card a worded event names by its Journal row id, so the read can name each Card once. Covers the
    /// events ``NightWording`` words with a Card's name.
    static func cardID(of event: JournalEvent) -> Int64? {
        switch event {
        case .attemptEnded(let id, _, _, _, _, _),
            .checkRan(let id, _, _, _, _, _, _, _),
            .cardStateTransitioned(let id, _, _, _, _, _),
            .cardLeaseReclaimed(let id, _, _),
            .readinessCheckFailed(let id, _, _):
            id
        case .waitingOnYouUnbacked(_, let id, _):
            id
        default:
            nil
        }
    }

    /// The Feature Issue a worded event names by its issue id, so the read can name each Feature once. Covers the
    /// events ``NightWording`` words with a Feature's name.
    static func featureIssueID(of event: JournalEvent) -> String? {
        switch event {
        case .authoringSkippedFeatureInFlight(let id),
            .authoringPredecessorNotLanded(let id, _),
            .featureReturned(_, let id, _, _, _):
            id
        case .featureAuthored(let payload):
            payload.featureIssueID
        default:
            nil
        }
    }

    /// The Night's close reason in plain words.
    static func words(closeReason: NightCloseReason) -> String {
        switch closeReason {
        case .nightEnd: "reached Night end"
        case .openedAndDied: "opened and died"
        case .projectRemoved: "Project removed"
        }
    }

    /// Why an Act did nothing, in plain words.
    static func words(idleReason: ActIdleReason) -> String {
        switch idleReason {
        case .unfinishedCardsPresent: "Cards are still left to work, so there is nothing to author"
        case .noFeatureInFlight: "no Feature is in flight"
        case .cycleHasNoUnfinishedCards: "the Cycle has nothing left to build"
        case .cycleHasUnfinishedCards: "the Cycle still has unfinished Cards"
        case .cycleAlreadyLanded: "the Cycle has already landed"
        }
    }

    /// An Authoring Halt's cause in words. `kind` is ``AuthoringHaltCause/kind``; an unknown kind reads as
    /// itself. Only what the engine recorded about itself is added: a seam or a Work Card title is the
    /// breakdown's own text, so those causes carry no detail.
    static func words(haltKind kind: String, detail: String?) -> String {
        let plain = haltPhrases[kind] ?? kind
        guard let detail, haltKindsNamingDetail.contains(kind) || haltPhrases[kind] == nil else { return plain }
        return "\(plain): \(detail)"
    }

    private static let haltPhrases: [String: String] = [
        "no-backward-compatible-seam": "no backward-compatible seam was found",
        "repositories-undetermined": "the repositories it touches could not be determined",
        "contract-outside-project": "it names a repository outside this Project",
        "contract-unreadable": "a contract could not be read from mainline",
        "authoring-repeatedly-faulted": "authoring faulted repeatedly",
        "feature-spans-repo-dependency": "it spans a Repo Dependency",
        "breakdown-consumes-own-feature-work": "a Work Card reads what another of its Cards writes"
    ]

    /// The halt causes whose detail is the engine's own: a repository, a fault count and reason, a Repo
    /// Dependency edge.
    private static let haltKindsNamingDetail: Set<String> = [
        "contract-outside-project", "authoring-repeatedly-faulted", "feature-spans-repo-dependency"
    ]

    /// A land step and what it yielded, in words: `seshes-backend: push failed`, `Verification failed`.
    static func words(step: LandStep, outcome: LandStepOutcome, repository: String?) -> String {
        let name = words(step: step)
        let result = words(outcome: outcome)
        guard let repository else { return "\(name.prefix(1).uppercased() + name.dropFirst()) \(result)" }
        return "\(repository): \(name) \(result)"
    }

    private static func words(step: LandStep) -> String {
        switch step {
        case .mergeTest: "merge test"
        case .push: "push"
        case .openPullRequest: "pull request"
        case .releaseWorktree: "Worktree release"
        case .verification: "Verification"
        case .returnFeature: "return of the Feature"
        case .archiveCycle: "archiving the Cycle"
        }
    }

    private static func words(outcome: LandStepOutcome) -> String {
        switch outcome {
        case .completed: "completed"
        case .notWired: "not wired yet"
        case .rehearsalBoundary: "not run — rehearsal"
        case .skipped: "skipped"
        case .failed: "failed"
        }
    }

    /// Event types that are a problem whatever their payload. ``isProblem(_:)`` adds the five events whose
    /// payload decides.
    private static let problemTypes: Set<JournalEventType> = [
        .linearAuthorizationHalted, .linearUnreachableHalted, .mainlineFetchFailed, .absentNightDetected,
        .nightOpenedAndDied, .leaseReclaimed, .cardLeaseReclaimed, .notificationDeliveryFailed,
        .boardWriteFailed, .outboxGroupRolledBack, .managedBlockDelimiterBroken, .managedBlockOverBudget,
        .worktreeNameCollision,
        .boardScopeUnresolved, .rateBudgetExhausted, .authoringInvariantBroken, .worktreeLost,
        .worktreeReconciliationFailed, .featureAuthoringFailed, .featureBreakdownRejected, .featureSelectionFailed,
        .mainlineConflictDetected, .readinessCheckFailed, .waitingOnYouUnbacked
    ]

    /// Whether the event is a problem the account puts first. Agrees with `JournalFailures` where they
    /// overlap: an `actIncomplete`, and a `repoLaneEnded` that records a failure. A Check declared none
    /// ran nothing, so only a failed Check is one; likewise only a failed land step and only an Attempt that
    /// hard-failed. An Authoring Halt and a usage limit are decisions and deferrals, not failures, so they
    /// are not (morning-report/disclose-a-failure).
    static func isProblem(_ record: JournalEventRecord) -> Bool {
        switch record.event {
        case .actIncomplete: true
        case .repoLaneEnded(_, _, .some, _): true
        case .checkRan(_, _, _, let result, _, _, _, _): result == .failed
        case .landStep(_, _, let outcome, _): outcome == .failed
        case .attemptEnded(_, _, _, _, let outcome, _): outcome == AttemptOutcome.hardFailure.rawValue
        default: problemTypes.contains(record.type)
        }
    }

    /// An event type's name in plain words: `WorktreeWIPCommitted` reads `Worktree WIP committed`. An
    /// acronym stays as written; every other word after the first is lowercase.
    static func plainName(of type: JournalEventType) -> String {
        let characters = Array(type.rawValue)
        var words: [String] = []
        var current = ""
        for (index, character) in characters.enumerated() {
            if !current.isEmpty, startsWord(at: index, in: characters) {
                words.append(current)
                current = ""
            }
            current.append(character)
        }
        words.append(current)
        return words.enumerated().map { index, word in
            index == 0 || isAcronym(word) ? word : word.lowercased()
        }.joined(separator: " ")
    }

    /// Whether an upper-case letter opens a word: after a lower-case letter or digit, or as the last
    /// capital of an acronym that a lower-case letter follows (`CLIProcess` splits before the `P`).
    private static func startsWord(at index: Int, in characters: [Character]) -> Bool {
        guard index > 0, characters[index].isUppercase else { return false }
        let previous = characters[index - 1]
        if previous.isLowercase || previous.isNumber { return true }
        return index + 1 < characters.count && characters[index + 1].isLowercase
    }

    private static func isAcronym(_ word: String) -> Bool {
        word.count > 1 && word.allSatisfy { $0.isUppercase || $0.isNumber }
    }
}

/// A headline and an optional detail line.
struct NightWords {
    var headline: String
    var detail: String?
}

/// Words one event, given the Act that recorded it and the Cards' and Features' display identifiers.
struct NightWording {
    let act: Act?
    let cardNames: [Int64: String]
    /// A Feature Issue's id to its display identifier.
    let featureNames: [String: String]

    /// `Build Act`, or `Act` when the event records no Act.
    var actName: String { act.map { "\($0.rawValue.capitalized) Act" } ?? "Act" }

    func card(_ id: Int64) -> String { cardNames[id] ?? "Card \(id)" }

    /// A Feature Issue's display identifier, or its raw issue id when the Journal has no Feature row for it.
    func feature(_ issueID: String) -> String { featureNames[issueID] ?? issueID }

    func count(_ number: Int, _ noun: String) -> String { "\(number) \(noun)\(number == 1 ? "" : "s")" }

    func words(for event: JournalEvent) -> NightWords {
        lifecycle(event) ?? night(event) ?? infrastructure(event) ?? infrastructureFailures(event) ?? cards(event)
            ?? authoring(event) ?? landing(event) ?? NightWords(headline: NightAccount.plainName(of: event.type))
    }
}
