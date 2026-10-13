import Foundation

// What a view of the Night's account asks of its runs: their lanes, their last moment, and their outcomes in
// plain words. Plain values only; how an outcome looks, colour included, is the app's.

extension NightAccount {
    /// Author, Build and Land, and a lane for unstamped events when any run carries no Act.
    public var lanes: [String?] {
        let acts: [String?] = ["author", "build", "land"]
        return runs.contains { $0.act == nil } ? acts + [nil] : acts
    }

    /// `Build Act`, or `No Act run` for the events no run stamped.
    static func name(ofAct act: String?) -> String {
        act.map { "\($0.capitalized) Act" } ?? "No Act run"
    }
}

extension NightAccount.ActRun {
    /// `Build Act`, or `No Act run` for the events no run stamped.
    public var actName: String { NightAccount.name(ofAct: act) }

    /// `Build Act · 14:00`, the run's name and the time it started.
    public var title: String { "\(actName) \u{00B7} \(startedAt.formatted(.dateTime.hour().minute()))" }

    /// The time of the run's last entry, or its start when it has none.
    public var lastAt: Date { entries.last?.occurredAt ?? startedAt }
}

extension NightAccount.RunOutcome {
    /// How the run ended, in plain words, with its reason when it has one. Never "running".
    public var words: String {
        switch self {
        case .ended: "ended"
        case .idle(let reason): "idle \u{2014} \(reason)"
        case .incomplete(let reason): "could not complete \u{2014} \(reason)"
        case .stoodDown: "stood down"
        case .notEnded: "not ended"
        }
    }

    /// How the run ended as a verb phrase, to follow "it" or "the 14:00 run": `ended`, `was idle — <reason>`.
    /// A run with no closing event `recorded no end`. Never "running".
    public var predicate: String {
        switch self {
        case .ended: "ended"
        case .idle(let reason): "was idle \u{2014} \(reason)"
        case .incomplete(let reason): "could not complete \u{2014} \(reason)"
        case .stoodDown: "stood down"
        case .notEnded: "recorded no end"
        }
    }

    /// The outcome alone, without its reason.
    public var shortWords: String {
        switch self {
        case .ended: "ended"
        case .idle: "idle"
        case .incomplete: "could not complete"
        case .stoodDown: "stood down"
        case .notEnded: "not ended"
        }
    }

    /// Whether the run did nothing: it found no work, or another run held the Project.
    public var isQuiet: Bool {
        switch self {
        case .idle, .stoodDown: true
        case .ended, .incomplete, .notEnded: false
        }
    }
}
