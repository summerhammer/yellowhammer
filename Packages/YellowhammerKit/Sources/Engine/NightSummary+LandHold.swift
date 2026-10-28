import Domain
import Foundation
import Journal

extension NightSummary {
    /// Every Work Card for which the hold lasted this Night, including Cards resumed between land ticks.
    public static func landHoldCardLines(night: NightRecord, journal: JournalStore) throws -> [String] {
        var seen: Set<Int64> = []
        let cardIDs = try journal.landHolds(nightID: night.id).flatMap(\.cardIDs).filter {
            seen.insert($0).inserted
        }
        return try cardIDs.map {
            "\(cardName(try journal.card(id: $0))) — kept the land Act from firing."
        }
    }

    /// No hold means no proximity line. Each clock restart is a separate span, and elapsed minutes are
    /// capped at the Bound even when the required build read makes the hold last longer.
    static func answerWaitProximity(night: NightRecord, journal: JournalStore) throws -> BoundProximity? {
        let holds = try journal.landHolds(nightID: night.id)
        func seconds(_ hold: LandHoldRecord) -> TimeInterval {
            max(0, (hold.endedAt ?? night.completedAt ?? hold.endsAt).timeIntervalSince(hold.startedAt))
        }
        guard let longest = holds.max(by: { seconds($0) < seconds($1) }) else { return nil }
        let elapsed = seconds(longest)
        let ranOut = elapsed >= Double(longest.answerWaitMinutes) * 60
        let ending = ranOut ? "ran out" : (longest.endReason ?? "hold in progress")
        return BoundProximity(
            name: "answer_wait_minutes", value: longest.answerWaitMinutes,
            observed: min(longest.answerWaitMinutes, Int(elapsed / 60)),
            measure: "longest hold in minutes; \(ending)"
        )
    }
}
