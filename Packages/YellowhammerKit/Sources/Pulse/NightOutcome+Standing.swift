import Domain
import Foundation

/// A Night's ``NightOutcome`` read against its mode and whether it closed: whether it ended without shipping, the
/// verdict facts it adds, and the Sidebar mark's text when no Act failed.
struct NightStanding: Equatable, Sendable {
    let outcome: NightOutcome
    let mode: NightMode
    /// Whether the Night is closed (done), not still running.
    let isClosed: Bool

    /// A closed real Night in which Cards were worked to an outcome and nothing was delivered. A rehearsal Night
    /// never is: it ships nothing by definition. A Night whose Attempts only asked questions, or were cancelled or
    /// aborted, is not: those are decisions, not failures.
    var endedWithoutShipping: Bool {
        isClosed && mode == .real && outcome.cardsWithOutcome > 0 && !outcome.deliveredWork
    }

    /// `1 Attempt`, `2 Attempts`.
    static func counted(_ count: Int, _ noun: String, plural: String? = nil) -> String {
        "\(count) \(count == 1 ? noun : plural ?? noun + "s")"
    }

    /// The verdict facts the Night's own events add, in verdict order.
    var verdictFacts: [String] {
        var facts: [String] = []
        if mode == .rehearsal { facts.append("Rehearsal Night — nothing ships in a rehearsal") }
        if endedWithoutShipping {
            let cards = Self.counted(outcome.cardsWithOutcome, "Card")
            facts.append("Nothing shipped — \(cards) worked, no Cycle landed")
        }
        if let fact = Self.attemptFact(outcome.roundsExhausted, ending: "rounds-exhausted") { facts.append(fact) }
        if let fact = Self.attemptFact(outcome.hardFailures, ending: "hard-failed") { facts.append(fact) }
        if !outcome.redChecks.isEmpty {
            facts.append("Check stayed red on \(outcome.redChecks.map(\.cardName).joined(separator: ", "))")
        }
        for limit in outcome.usageLimits {
            let until = limit.until.formatted(date: .omitted, time: .shortened)
            let times = Self.counted(limit.occurrence.count, "time")
            facts.append("\(limit.cli) usage limit, \(times) — until \(until)")
        }
        return facts
    }

    /// Said only when no other fact applies: a Night with Attempt events is never "verdict unknown".
    var fallbackFact: String? {
        guard outcome.attemptsEnded > 0 else { return nil }
        let attempts = Self.counted(outcome.attemptsEnded, "Attempt")
        return "\(attempts) ended on \(Self.counted(outcome.cardsWorked, "Card"))"
    }

    private static func attemptFact(_ problems: [NightOutcome.CardProblem], ending: String) -> String? {
        guard !problems.isEmpty else { return nil }
        let attempts = counted(problems.reduce(0) { $0 + $1.occurrence.count }, "Attempt")
        return "\(attempts) \(ending) (\(problems.map(\.cardName).joined(separator: ", ")))"
    }

    /// The first unrecovered Card problem by event id: `YLH-406: 2 Attempts rounds-exhausted`.
    var firstCardProblem: String? {
        let rounds = outcome.roundsExhausted.map { ($0, "rounds-exhausted") }
        let hard = outcome.hardFailures.map { ($0, "hard-failed") }
        guard let first = (rounds + hard).min(by: { $0.0.occurrence.firstEventID < $1.0.occurrence.firstEventID })
        else { return nil }
        return "\(first.0.cardName): \(Self.counted(first.0.occurrence.count, "Attempt")) \(first.1)"
    }

    /// The Sidebar mark's text when no Act failed: "Night ended without shipping" (with the first Card problem),
    /// else the first Card problem, else the first Night-derived Health flag. A usage limit alone sets nothing.
    func problemHeadline(nightID: Int64) -> String? {
        if endedWithoutShipping {
            return "Night ended without shipping" + (firstCardProblem.map { ": \($0)" } ?? "")
        }
        if let problem = firstCardProblem { return problem }
        return HealthFlag.nightFlags(outcome, nightID: nightID).first { $0.kind != .usageLimited }?.id
    }
}
