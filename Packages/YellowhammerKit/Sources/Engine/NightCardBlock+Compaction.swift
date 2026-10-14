import Foundation

/// How far a completed Night Card is compacted to stay within the Board Connection's description budget
/// (spec: board-projection/write-the-night-summary, "night-card-budget"). The `**Verdict:**` line never
/// compacts, and every collapse states its count. The default compacts nothing.
public struct NightCardCompaction: Equatable, Sendable {
    /// How many of the Cards section's lines keep their detail, the most recent in section order; the rest
    /// become one short line per Work Card. Nil keeps them all.
    public var detailedCards: Int?
    /// How many entries each Standing section keeps; the rest collapse into one line. Nil keeps them all.
    public var standingKept: Int?
    /// How many Exception lines are kept, the most recent; the rest collapse into one line. Nil keeps them all.
    public var exceptionsKept: Int?

    public init(detailedCards: Int? = nil, standingKept: Int? = nil, exceptionsKept: Int? = nil) {
        self.detailedCards = detailedCards
        self.standingKept = standingKept
        self.exceptionsKept = exceptionsKept
    }

    /// The most a stage keeps at each of its steps, descending: a few steps, never one rendering per line.
    private static let keepLevels = [8, 4, 2, 0]

    /// The compactions to try, in order: none first, then Cards' detail, then the Standing sections' entries,
    /// then the Exception lines, each stage keeping fewer than the one before and stopping at none kept.
    /// `cards`, `standing` (the longest Standing section) and `exceptions` are the sections' line counts.
    public static func ladder(cards: Int, standing: Int, exceptions: Int) -> [NightCardCompaction] {
        var rungs = [NightCardCompaction()]
        var current = NightCardCompaction()
        for (count, keep) in [
            (cards, \NightCardCompaction.detailedCards),
            (standing, \NightCardCompaction.standingKept),
            (exceptions, \NightCardCompaction.exceptionsKept)
        ] {
            for level in keepLevels where level < count {
                var rung = current
                rung[keyPath: keep] = level
                rungs.append(rung)
            }
            if count > 0 { current[keyPath: keep] = 0 }
        }
        return rungs
    }

    func cardLines(detailed: [String], short: [String]) -> [String] {
        guard let detailedCards, detailed.count > detailedCards, short.count == detailed.count else {
            return detailed
        }
        let shortened = detailed.count - detailedCards
        return Array(short.prefix(shortened)) + Array(detailed.suffix(detailedCards))
    }

    /// The first `standingKept` entries, then one line naming how many were left out.
    func standing(_ items: [String]) -> [String] {
        guard let standingKept, items.count > standingKept else { return items }
        let collapsed = Self.collapsedLine(count: items.count - standingKept, kept: standingKept)
        return Array(items.prefix(standingKept)) + [collapsed]
    }

    /// One line naming how many were left out, then the most recent `exceptionsKept` lines.
    func exceptions(_ items: [String]) -> [String] {
        guard let exceptionsKept, items.count > exceptionsKept else { return items }
        return [Self.collapsedLine(count: items.count - exceptionsKept, kept: exceptionsKept)]
            + Array(items.suffix(exceptionsKept))
    }

    private static func collapsedLine(count: Int, kept: Int) -> String {
        kept > 0
            ? "and \(count) more — see the app"
            : "\(count) \(count == 1 ? "entry" : "entries") — see the app"
    }
}
