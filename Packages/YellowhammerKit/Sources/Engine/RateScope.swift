import Domain
import Foundation
import Journal

/// The scope of Nights and events contributing to instrumented rate calculations and Bound proximity.
/// Rehearsal Nights are isolated from real Nights: a rate scope only includes Nights matching the target
/// Night's `mode` (OQ140).
public struct RateScope: Sendable, Equatable {
    public let mode: NightMode
    public let nights: [NightRecord]
    public let nightIDs: Set<Int64>

    public init(mode: NightMode, nights: [NightRecord]) {
        self.mode = mode
        self.nights = nights
        self.nightIDs = Set(nights.map(\.id))
    }

    public init(night: NightRecord, journal: JournalStore) throws {
        self.mode = night.mode
        var candidateNights = try journal.nights(mode: night.mode).filter { $0.nightStart <= night.nightStart }
        if !candidateNights.contains(where: { $0.id == night.id }) {
            candidateNights.append(night)
            candidateNights.sort { $0.nightStart < $1.nightStart }
        }
        self.nights = candidateNights
        self.nightIDs = Set(candidateNights.map(\.id))
    }
}
