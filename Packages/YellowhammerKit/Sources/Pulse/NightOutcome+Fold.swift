import Domain
import Foundation
import Journal

/// The display names a ``NightOutcome`` fold is handed, so the fold reads no Journal.
struct NightOutcomeNames {
    let cards: [Int64: String]
    let issues: [String: String]
    let attemptRoutes: [Int64: String]
}

extension NightOutcome {
    /// An empty outcome; only the fold starts from it.
    init() {}

    /// The accumulator `init(events:)` runs the Night's events through.
    struct Fold {
        let names: NightOutcomeNames
        let recovered: Set<Int64>
        var outcome = NightOutcome()
        var worked: Set<Int64> = []
        var rounds: [Int64: CardProblem] = [:]
        var hard: [Int64: CardProblem] = [:]
        var checkFailures: [Int64: CardProblem] = [:]
        var lastCheckFailed: [Int64: Bool] = [:]
        var limits: [String: UsageLimit] = [:]
        var excluded: [String: ExcludedRoute] = [:]
        var excludedAttempts: Set<Int64> = []
        var causes: [String: RecurringCause] = [:]

        init(names: NightOutcomeNames, recovered: Set<Int64>) {
            self.names = names
            self.recovered = recovered
        }

        /// Cards whose last `attemptEnded` is `success`: a later Attempt recovered whatever failed before.
        static func recoveredCards(_ events: [JournalEventRecord]) -> Set<Int64> {
            var last: [Int64: String] = [:]
            for record in events {
                if case .attemptEnded(let cardID, _, _, _, let outcome, _) = record.event { last[cardID] = outcome }
            }
            return Set(last.filter { $0.value == AttemptOutcome.success.rawValue }.keys)
        }

        func name(_ cardID: Int64, _ issueID: String) -> String { names.cards[cardID] ?? issueID }

        mutating func add(_ record: JournalEventRecord) {
            switch record.type {
            case .attemptEnded: addAttempt(record)
            case .checkRan: addCheck(record)
            case .routeUsageLimited: addUsageLimit(record)
            case .cardReclaimed: addReclaim(record)
            case .failureCauseRecorded: addCause(record)
            default: addDelivery(record)
            }
            addNote(record)
        }

        mutating func addDelivery(_ record: JournalEventRecord) {
            switch record.event {
            case .cycleLanded: outcome.deliveredWork = true
            case .landStep(.openPullRequest, _, .completed, _): outcome.deliveredWork = true
            case .cardStateTransitioned(_, _, _, .done, _, _): outcome.deliveredWork = true
            default: break
            }
        }

        mutating func addAttempt(_ record: JournalEventRecord) {
            guard case .attemptEnded(let cardID, let issueID, let attemptID, let route, let ending, let excludes)
                = record.event else { return }
            outcome.attemptsEnded += 1
            worked.insert(cardID)
            guard !recovered.contains(cardID) else { return }
            let card = name(cardID, issueID)
            if ending == AttemptOutcome.roundsExhausted.rawValue {
                Self.bump(&rounds, cardID, card, record)
            } else if ending == AttemptOutcome.hardFailure.rawValue {
                Self.bump(&hard, cardID, card, record)
            }
            if excludes {
                exclude(route: route.description, reason: ending, card: card, attemptID: attemptID, record)
            }
        }

        mutating func addReclaim(_ record: JournalEventRecord) {
            guard case .cardReclaimed(let cardID, let issueID, _, let attemptID, let ending, true) = record.event,
                  !recovered.contains(cardID) else { return }
            let route = attemptID.flatMap { names.attemptRoutes[$0] } ?? "unknown Route"
            exclude(
                route: route, reason: ending ?? "reclaimed", card: name(cardID, issueID),
                attemptID: attemptID, record
            )
        }

        /// One excluded Attempt per Route; the Attempt a reclaim classified is also an `attemptEnded`, counted once.
        mutating func exclude(
            route: String, reason: String, card: String, attemptID: Int64?, _ record: JournalEventRecord
        ) {
            if let attemptID, !excludedAttempts.insert(attemptID).inserted { return }
            if var existing = excluded[route] {
                existing.occurrence.add(record)
                if !existing.cardNames.contains(card) { existing.cardNames.append(card) }
                excluded[route] = existing
            } else {
                excluded[route] = ExcludedRoute(
                    route: route, reason: reason, cardNames: [card], occurrence: Occurrence(record)
                )
            }
        }

        mutating func addCheck(_ record: JournalEventRecord) {
            guard case .checkRan(let payload) = record.event else { return }
            let failed = payload.result == .failed
            lastCheckFailed[payload.cardID] = failed
            guard failed else { return }
            Self.bump(&checkFailures, payload.cardID, name(payload.cardID, payload.issueID), record)
        }

        mutating func addUsageLimit(_ record: JournalEventRecord) {
            guard case .routeUsageLimited(_, let cli, let until, let hint) = record.event else { return }
            if var existing = limits[cli] {
                existing.occurrence.add(record)
                existing.until = max(existing.until, until)
                existing.resetHint = hint ?? existing.resetHint
                limits[cli] = existing
            } else {
                limits[cli] = UsageLimit(cli: cli, until: until, resetHint: hint, occurrence: Occurrence(record))
            }
        }

        mutating func addCause(_ record: JournalEventRecord) {
            guard case .failureCauseRecorded(let cardID, let issueID, let cause, let hash, let recurrence)
                = record.event, recurrence > 1, !recovered.contains(cardID) else { return }
            let key = "\(cardID)|\(hash)"
            if var existing = causes[key] {
                existing.occurrence.add(record)
                existing.recurrenceCount = max(existing.recurrenceCount, recurrence)
                causes[key] = existing
            } else {
                causes[key] = RecurringCause(
                    cardName: name(cardID, issueID), cause: cause, recurrenceCount: recurrence,
                    occurrence: Occurrence(record)
                )
            }
        }

        static func bump(
            _ problems: inout [Int64: CardProblem], _ cardID: Int64, _ card: String, _ record: JournalEventRecord
        ) {
            if var existing = problems[cardID] {
                existing.occurrence.add(record)
                problems[cardID] = existing
            } else {
                problems[cardID] = CardProblem(cardName: card, occurrence: Occurrence(record))
            }
        }

        func finish() -> NightOutcome {
            var result = outcome
            result.cardsWorked = worked.count
            result.roundsExhausted = Self.ordered(rounds.values)
            result.hardFailures = Self.ordered(hard.values)
            result.redChecks = Self.ordered(checkFailures.filter {
                lastCheckFailed[$0.key] == true && !recovered.contains($0.key)
            }.values)
            result.usageLimits = limits.values.sorted { $0.occurrence.firstEventID < $1.occurrence.firstEventID }
            result.excludedRoutes = excluded.values.sorted { $0.occurrence.firstEventID < $1.occurrence.firstEventID }
            result.recurringCauses = causes.values.sorted { $0.occurrence.firstEventID < $1.occurrence.firstEventID }
            return result
        }

        static func ordered(_ problems: Dictionary<Int64, CardProblem>.Values) -> [CardProblem] {
            problems.sorted { $0.occurrence.firstEventID < $1.occurrence.firstEventID }
        }
    }
}
