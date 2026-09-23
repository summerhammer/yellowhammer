import Domain
import Foundation
import Journal

// The Night Summary's `**Verdict:**` line (roadmap P12.1): one constant-time sentence, a closed
// vocabulary, joined by " · " — never a list, never growing with the Night. Three facts: how the
// Night ended, whether it advanced, and how many decisions are waiting.

extension NightSummary {
    /// Events whose presence this Night means the Night crashed: a lease of any scope was reclaimed,
    /// or the previous Night opened and died.
    private static let crashEventTypes: Set<JournalEventType> = [
        .leaseReclaimed, .cardLeaseReclaimed, .cardReclaimed, .nightOpenedAndDied
    ]

    /// Advancing without landing: a Card state transition, an Attempt ending, or a Feature being
    /// authored — any of these this Night, with no `cycleLanded`.
    private static let advancingEventTypes: Set<JournalEventType> = [
        .cardStateTransitioned, .attemptEnded, .featureAuthored
    ]

    /// A quiet authoring reason this Night: skipped-in-flight, predecessor not landed or
    /// indeterminate, a Refusal, or an Authoring Halt.
    private static let quietAuthoringEventTypes: Set<JournalEventType> = [
        .authoringSkippedFeatureInFlight, .authoringPredecessorNotLanded, .authoringPredecessorIndeterminate,
        .refusalOpened, .refusalRepeated, .authoringHaltOpened, .authoringHaltRepeated, .featureAuthoringHalted
    ]

    /// The Night Summary's one constant-time `**Verdict:**` line. A normal ending renders last
    /// (`<decisions> · <advance> · closed`); an abnormal ending (`crashed`/`halted`) is promoted to the
    /// front (`crashed · <decisions> · <advance>`).
    public static func verdictLine(night: NightRecord, journal: JournalStore) throws -> String {
        let events = try nightEvents(night: night, journal: journal)
        let ending = endingWord(events: events)
        let advance = try advanceWord(night: night, journal: journal, events: events)
        let decisions = try decisionsPhrase(night: night, journal: journal)
        switch ending {
        case .crashed, .halted:
            return "\(ending.rawValue) · \(decisions) · \(advance)"
        case .closed:
            return "\(decisions) · \(advance) · \(ending.rawValue)"
        }
    }

    private enum Ending: String {
        case crashed, halted, closed
    }

    private static func endingWord(events: [JournalEventRecord]) -> Ending {
        if events.contains(where: { crashEventTypes.contains($0.type) }) {
            return .crashed
        }
        if events.contains(where: { $0.type == .actIncomplete }) {
            return .halted
        }
        return .closed
    }

    private static func advanceWord(
        night: NightRecord, journal: JournalStore, events: [JournalEventRecord]
    ) throws -> String {
        if let landed = events.first(where: { $0.type == .cycleLanded }) {
            guard case .cycleLanded(let cycleID) = landed.event else { return "advanced without landing" }
            let holes = try journal.laneHoles(cycleID: cycleID)
            return holes.isEmpty ? "landed" : "landed partially — Partial Landing"
        }
        if events.contains(where: { advancingEventTypes.contains($0.type) }) {
            return "advanced without landing"
        }
        if night.verdict == .idle {
            return "did not advance — idle"
        }
        if events.contains(where: { quietAuthoringEventTypes.contains($0.type) }) {
            return "did not advance — quiet"
        }
        return "did not advance"
    }

    /// `N decisions waiting` — Cards of the in-flight Cycle currently Blocked or Waiting on You — plus,
    /// when an in-flight Feature has landed but this Night is not yet triaged, the unsettled Feature
    /// that holds them.
    private static func decisionsPhrase(night: NightRecord, journal: JournalStore) throws -> String {
        let waiting: Int
        if let cycleID = try journal.inFlightCycleID() {
            waiting = try journal.laneHoles(cycleID: cycleID).count
        } else {
            waiting = 0
        }
        let inFlightLanded = try journal.inFlightLandedFeature()
        let unsettled = inFlightLanded != nil && night.triagedAt == nil

        guard waiting != 0 || unsettled else {
            return "no decisions waiting"
        }
        var phrase = "\(waiting) decision\(waiting == 1 ? "" : "s") waiting"
        if unsettled, let feature = inFlightLanded?.feature {
            phrase += ", held by unsettled Feature `\(feature.issueID)`"
        }
        return phrase
    }
}
