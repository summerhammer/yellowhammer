import Domain
import Foundation
import Journal

/// The Project file's firing grid, resolved for this invocation's Night by EngineCommand.
public struct LandHoldSchedule: Equatable, Sendable {
    public let start: Date
    public let end: Date
    public let buildEveryMinutes: Int
    public let answerWaitMinutes: Int

    public init(start: Date, end: Date, buildEveryMinutes: Int = 15, answerWaitMinutes: Int = 30) {
        self.start = start
        self.end = end
        self.buildEveryMinutes = buildEveryMinutes
        self.answerWaitMinutes = answerWaitMinutes
    }

    func nextLand(atOrAfter date: Date) -> Date {
        let seconds = Double(buildEveryMinutes) * 60
        let tick = max(1, ceil(date.timeIntervalSince(start) / seconds))
        return min(end, start.addingTimeInterval(tick * seconds))
    }

    func projectedEnd(startedAt: Date, asOf: Date, hasBuildRead: Bool) -> Date {
        let seconds = Double(buildEveryMinutes) * 60
        let offset = buildEveryMinutes == 1 ? 0.0 : 60.0
        let reference = hasBuildRead ? startedAt : max(startedAt, asOf)
        let tick = max(1, floor((reference.timeIntervalSince(start) - offset) / seconds) + 1)
        let nextBuild = start.addingTimeInterval(tick * seconds + offset)
        let afterBuild = hasBuildRead ? start : nextLand(atOrAfter: nextBuild.addingTimeInterval(1))
        let expiry = nextLand(atOrAfter: startedAt.addingTimeInterval(Double(answerWaitMinutes) * 60))
        return min(end, max(expiry, afterBuild, nextLand(atOrAfter: asOf)))
    }
}

/// Shared by both triggers. The state of a Card and the meaning of unfinished never change.
enum LandHold {
    static func keepsLandFromFiring(_ card: CardRecord) -> Bool {
        guard !card.isRemovedFromBoard else { return false }
        if card.state == .waitingOnYou { return card.waitingReason == .question }
        return card.state == .blocked && [BlockReason.checkFailure, .routeFailure, .hostCrash, .engineFault]
            .contains { $0.rawValue == card.blockReason }
    }

    static func refresh(context: ActContext, now: Date = Date()) throws -> Bool {
        try refresh(journal: context.journal, nightID: context.night.id, runID: context.runID,
                    schedule: context.landHoldSchedule, now: now)
    }

    static func refresh(
        journal: JournalStore, nightID: Int64, runID: RunID, schedule supplied: LandHoldSchedule?, now: Date
    ) throws -> Bool {
        guard let schedule = supplied, let cycleID = try journal.inFlightCycleID(),
              try journal.night(id: nightID) != nil else { return false }
        if try journal.isCycleLanded(cycleID: cycleID) || journal.hasCycleHandoffBegun(cycleID: cycleID) {
            try journal.endLandHold(cycleID: cycleID, reason: "nothing kept land from firing", runID: runID, now: now)
            return false
        }
        guard try !journal.hasNightHoldEnded(nightID: nightID) else { return false }
        let cards = try journal.cards(cycleID: cycleID)
        let feature = try journal.feature(cycleID: cycleID)
        let origins = try feature.map { try journal.adoptionOrigins(featureIssueID: $0.issueID) } ?? [:]
        let heldCards = try RepoLane.heldCards(in: cards, adoptedFrom: origins) { try journal.card(id: $0.id) }
        let held = Set(heldCards.map { $0.card.id })
        let unfinished = cards.contains { $0.state.isUnfinished && !$0.isRemovedFromBoard && !held.contains($0.id) }
        let candidates = cards.filter(keepsLandFromFiring)
        if unfinished || candidates.isEmpty {
            let reason = unfinished ? "answer or re-ready" : "nothing kept land from firing"
            try journal.endLandHold(cycleID: cycleID, reason: reason,
                                    runID: runID, now: now)
            return false
        }
        let cardIDs = Set(cards.map(\.id)).subtracting(held)
        let transitions = try journal.events().filter {
            switch $0.event {
            case .cardStateTransitioned(let id, _, let from, let to, _, _):
                return cardIDs.contains(id) && from.isUnfinished && !to.isUnfinished
            case .cardShelved(let id, _, let previous):
                return cardIDs.contains(id) && previous.isUnfinished
            case .cardRemovedFromBoard(let id, _, _):
                return cards.contains { $0.id == id && $0.state.isUnfinished }
            default: return false
            }
        }
        let lastFinish = transitions.last
        let startedAt = max(schedule.start, lastFinish?.occurredAt ?? schedule.start)
        if let active = try journal.activeLandHold(cycleID: cycleID),
           active.nightID != nightID || active.startedAt < startedAt {
            try journal.endLandHold(cycleID: cycleID, reason: "answer or re-ready", runID: runID, now: now)
        }
        let hasRead = try hasBuildRead(journal: journal, nightID: nightID, cycleID: cycleID, since: startedAt)
        let endsAt = schedule.projectedEnd(startedAt: startedAt, asOf: now, hasBuildRead: hasRead)
        try journal.recordLandHold(nightID: nightID, cycleID: cycleID, cardIDs: candidates.map(\.id),
                                   startedAt: startedAt, endsAt: endsAt,
                                   answerWaitMinutes: schedule.answerWaitMinutes, runID: runID, now: now)
        return try journal.activeLandHold(cycleID: cycleID) != nil
    }

    static func canEnd(journal: JournalStore, cycleID: Int64, now: Date) throws -> Bool {
        guard let span = try journal.activeLandHold(cycleID: cycleID) else { return true }
        guard now >= span.startedAt.addingTimeInterval(Double(span.answerWaitMinutes) * 60) else { return false }
        return try hasBuildRead(journal: journal, nightID: span.nightID, cycleID: cycleID, since: span.startedAt)
    }

    private static func hasBuildRead(
        journal: JournalStore, nightID: Int64, cycleID: Int64, since start: Date
    ) throws -> Bool {
        let ids = Set(try journal.cards(cycleID: cycleID).map(\.id))
        let events = try journal.events()
        let lastFinish = events.last {
            guard $0.occurredAt <= start else { return false }
            switch $0.event {
            case .cardStateTransitioned(let id, _, let from, let to, _, _):
                return ids.contains(id) && from.isUnfinished && !to.isUnfinished
            case .cardShelved(let id, _, let previous): return ids.contains(id) && previous.isUnfinished
            case .cardRemovedFromBoard(let id, _, _): return ids.contains(id)
            default: return false
            }
        }
        return events.contains {
            $0.type == .deltaReadCompleted && $0.act == .build && $0.nightID == nightID && $0.occurredAt >= start
                && ($0.occurredAt > start || $0.id > (lastFinish?.id ?? 0))
        }
    }
}
