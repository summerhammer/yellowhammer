import Domain
import Foundation
import Journal

// The Night Summary's `**Verdict:**` line (roadmap P12.1): one constant-time sentence, a closed
// vocabulary, joined by " · " — never a list, never growing with the Night. Three facts: how the
// Night ended, whether it advanced, and how many decisions are waiting.

extension NightSummary {
    /// Advancing without landing: a Card state transition, an Attempt ending, or a Feature being
    /// authored — any of these this Night, with no `cycleLanded`.
    private static let advancingEventTypes: Set<JournalEventType> = [
        .cardStateTransitioned, .attemptEnded, .featureAuthored
    ]

    /// A quiet authoring reason this Night: skipped-in-flight, predecessor not landed or
    /// indeterminate, a Refusal, an Authoring Halt, or the release gate holding a consumer.
    private static let quietAuthoringEventTypes: Set<JournalEventType> = [
        .authoringSkippedFeatureInFlight, .authoringPredecessorNotLanded, .authoringPredecessorIndeterminate,
        .refusalOpened, .refusalRepeated, .authoringHaltOpened, .authoringHaltRepeated, .featureAuthoringHalted,
        .authoringReleaseGateHeld
    ]

    /// The Night Summary's one constant-time `**Verdict:**` line. A normal ending renders last
    /// (`<decisions> · <advance> · closed`); an abnormal ending (`crashed`/`halted`) is promoted to the
    /// front (`crashed · <decisions> · <advance>`). The ending is abnormal only when the Night's ending was:
    /// see ``endingWord(night:events:renderingRunID:)``. `renderingRunID` is the Act computing the line.
    public static func verdictLine(
        night: NightRecord, journal: JournalStore, renderingRunID: RunID? = nil
    ) throws -> String {
        let events = try nightEvents(night: night, journal: journal)
        let ending = endingWord(night: night, events: events, renderingRunID: renderingRunID)
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

    /// `crashed` when the Night's own close reason is `opened_and_died` (read from the record: the
    /// `nightOpenedAndDied` event is stamped on the *next* Night, about this one's predecessor). Otherwise
    /// `halted`/`crashed` iff the last non-flush Act halted/crashed, and `closed` whatever failed earlier —
    /// a failure a later Act recovered is the `**Exceptions:**` section's line, not the ending's. Lease and
    /// Card reclaims no longer decide it; `**Crashes and reclaims:**` keeps reporting them.
    private static func endingWord(
        night: NightRecord, events: [JournalEventRecord], renderingRunID: RunID?
    ) -> Ending {
        if night.closeReason == .openedAndDied {
            return .crashed
        }
        switch nightRuns(events: events, renderingRunID: renderingRunID).last?.outcome {
        case .halted:
            return .halted
        case .crashed:
            return .crashed
        case .ended, nil:
            return .closed
        }
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

    /// `N decisions waiting` — Cards of the in-flight Cycle currently Blocked or Waiting on You,
    /// plus unresolved Authoring Halt Feature Cards (including those left Blocked by expiry). When an
    /// in-flight Feature has landed but this Night is not yet triaged, name the unsettled Feature.
    private static func decisionsPhrase(night: NightRecord, journal: JournalStore) throws -> String {
        var waiting = try journal.unresolvedAuthoringHaltCardCount()
        if let cycleID = try journal.inFlightCycleID() {
            waiting += try journal.laneHoles(cycleID: cycleID).count
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
