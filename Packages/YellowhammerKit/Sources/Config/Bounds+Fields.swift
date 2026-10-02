import Foundation

/// How the Add Project wizard explains each of the six per-Project Bounds. Each fires when its count
/// exceeds its value, so the copy says "up to".
extension Bounds {
    /// What happens when a Bound fires: the glossary's two consequence shapes, with "stops work" split
    /// by what it stops.
    public enum Consequence: CaseIterable, Sendable {
        case stopsCard
        case stopsAuthoring
        case raisesToYou

        public var title: String {
            switch self {
            case .stopsCard: "Stops a Card\u{2019}s work"
            case .stopsAuthoring: "Stops a Night\u{2019}s authoring"
            case .raisesToYou: "Raises it to you"
            }
        }

        public var footer: String {
            switch self {
            case .stopsCard: "When one is reached, the work stops and says why."
            case .stopsAuthoring: "When it is reached, that Night authors no further Feature."
            case .raisesToYou: "Nothing stops. The item becomes a standing decision for you."
            }
        }
    }

    /// One Bound as the wizard explains it.
    public struct Field: Sendable {
        /// The `[limits]` key.
        public let key: String
        public let title: String
        public let unit: String
        public let units: String
        /// What the number counts and what happens past it, in a sentence or two.
        public let explanation: String
        /// The Bound as one sentence around its value: "Wait up to" **3 Nights** "for your answer…".
        public let sentence: (before: String, after: String)
        public let consequence: Consequence
        public let keyPath: WritableKeyPath<Bounds, Int> & Sendable

        public func valueText(_ value: Int) -> String { "\(value) \(value == 1 ? unit : units)" }

        public var defaultValue: Int { Bounds()[keyPath: keyPath] }
    }

    /// The six Bounds, in the order the wizard lists them.
    public static let fields = [
        Field(
            key: "review_rounds_max", title: "Review Rounds per Attempt", unit: "round", units: "rounds",
            explanation: "How many times a review or Check can send the same work back for changes. Past "
                + "this, the Attempt ends and the Card moves to its next route with a fresh budget.",
            sentence: ("Send work back for changes up to", "per Attempt, then move the Card to its next route."),
            consequence: .stopsCard, keyPath: \Bounds.reviewRoundsMax
        ),
        Field(
            key: "attempts_per_card", title: "Attempts per Card", unit: "attempt", units: "attempts",
            explanation: "How many times a Card is dispatched, each on a different route. Past this, the "
                + "Card stops and says why. An aborted Attempt does not count.",
            sentence: ("Try a Card for up to", "on different routes, then stop it and say why."),
            consequence: .stopsCard, keyPath: \Bounds.attemptsPerCard
        ),
        Field(
            key: "unanswered_nights_max", title: "Unanswered Nights", unit: "Night", units: "Nights",
            explanation: "How many Nights a question put to you can stand unanswered. Past this, the Card "
                + "becomes Blocked with the question kept. Only Nights this Project runs count.",
            sentence: ("Wait up to", "for your answer, then mark the Card Blocked."),
            consequence: .stopsCard, keyPath: \Bounds.unansweredNightsMax
        ),
        Field(
            key: "reselections_max", title: "Re-selections per Night", unit: "more", units: "more",
            explanation: "When the Feature a Night picks is refused, how many more it picks. Past this, "
                + "that Night authors no further Feature.",
            sentence: ("If a Feature is refused, pick up to", "that Night, then stop authoring."),
            consequence: .stopsAuthoring, keyPath: \Bounds.reselectionsMax
        ),
        Field(
            key: "consecutive_refusals_max", title: "Refusals in a row", unit: "Refusal", units: "Refusals",
            explanation: "How many times in a row one Feature can be refused before it becomes a standing "
                + "decision for you. A clean authoring run of that Feature resets it.",
            sentence: ("Allow up to", "in a row for one Feature, then raise it to you."),
            consequence: .raisesToYou, keyPath: \Bounds.consecutiveRefusalsMax
        ),
        Field(
            key: "failed_adoptions_max", title: "Failed Adoptions in a row", unit: "failed Adoption",
            units: "failed Adoptions",
            explanation: "How many times in a row later Features can fail to take up a Card left Blocked or "
                + "Waiting on You before it becomes a standing decision for you.",
            sentence: ("Allow up to", "in a row for one Card, then raise it to you."),
            consequence: .raisesToYou, keyPath: \Bounds.failedAdoptionsMax
        )
    ]

    public static func fields(_ consequence: Consequence) -> [Field] {
        fields.filter { $0.consequence == consequence }
    }

    public var isDefault: Bool { self == Self() }

    /// Shown under every Bounds presentation: the numbers are set before there is any evidence.
    public static let evidenceNote = "Set before you have any evidence. Each Night Summary shows how close the "
        + "Night came to every Bound, so you can tune them later in Settings."
}
