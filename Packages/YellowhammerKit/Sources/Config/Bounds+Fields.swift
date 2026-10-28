import Foundation

/// How the Add Project wizard explains each of the nine per-Project Bounds.
extension Bounds {
    /// What happens when a Bound fires: the glossary's two consequence shapes, with "stops work" split
    /// by what it stops.
    public enum Consequence: CaseIterable, Sendable {
        case stopsCard
        case stopsAuthoring
        case raisesToYou
        case endsHold

        public var title: String {
            switch self {
            case .stopsCard: "Stops a Card\u{2019}s work"
            case .stopsAuthoring: "Stops a Night\u{2019}s authoring"
            case .raisesToYou: "Raises it to you"
            case .endsHold: "Ends the hold on the land Act"
            }
        }

        public var footer: String {
            switch self {
            case .stopsCard: "When one is reached, the work stops and says why."
            case .stopsAuthoring: "When it is reached, that Night authors no further Feature."
            case .raisesToYou: "Nothing stops. The item becomes a standing decision for you."
            case .endsHold: "The Cycle may land once a build Act has read the board."
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

    /// The nine Bounds, in the order the wizard lists them.
    public static let fields = [
        Field(
            key: "review_rounds_max", title: "Review Rounds per Attempt", unit: "round", units: "rounds",
            explanation: "How many times a review or Check can send the same work back for changes. Past "
                + "this, the Attempt ends and the Card moves to its next route with a fresh budget.",
            sentence: ("Send work back for changes up to", "per Attempt, then move the Card to its next route."),
            consequence: .stopsCard, keyPath: \Bounds.reviewRoundsMax
        ),
        Field(
            key: "attempts_per_work_card", title: "Attempts per Card", unit: "attempt", units: "attempts",
            explanation: "How many times a Card is dispatched, each on a different route. Past this, the "
                + "Card stops and says why. An aborted Attempt does not count.",
            sentence: ("Try a Card for up to", "on different routes, then stop it and say why."),
            consequence: .stopsCard, keyPath: \Bounds.attemptsPerWorkCard
        ),
        Field(
            key: "overdue_nights_max", title: "Unanswered Nights", unit: "Night", units: "Nights",
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
        ),
        Field(
            key: "consecutive_authoring_faults_max", title: "Authoring faults in a row", unit: "fault", units: "faults",
            explanation: "How many times in a row one Feature's authoring can fault. Past this, its next "
                + "selection halts authoring and asks you to force a new run. Accepted authoring resets it.",
            sentence: ("Allow up to", "in a row for one Feature, then halt its next authoring run."),
            consequence: .stopsAuthoring, keyPath: \Bounds.consecutiveAuthoringFaultsMax
        ),
        Field(
            key: "unmerged_features_max", title: "Unmerged Features", unit: "Feature", units: "Features",
            explanation: "How many implemented Features can await your merge. Once this many do, the author "
                + "Act authors nothing until a merge is observed.",
            sentence: ("Let up to", "await merge, then author nothing until one is merged."),
            consequence: .stopsAuthoring, keyPath: \Bounds.unmergedFeaturesMax
        ),
        Field(
            key: "answer_wait_minutes", title: "Wait for an answer", unit: "minute", units: "minutes",
            explanation: "How long the land Act waits for an answer or re-ready before handing off the Cycle.",
            sentence: ("Wait up to", "for an answer or re-ready before landing."),
            consequence: .endsHold, keyPath: \Bounds.answerWaitMinutes
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
