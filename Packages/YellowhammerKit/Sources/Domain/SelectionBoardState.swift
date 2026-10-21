import Foundation

/// What this Project's own Journal already knows about its board, handed to the selection pass so it has
/// no reason to go looking for state itself (issue #556). Plain values: no Journal types, and no issue
/// ids — only the human identifiers an Operator would recognise.
public struct SelectionBoardState: Equatable, Sendable {
    /// A Feature authored for this Project earlier.
    public struct AuthoredFeature: Equatable, Sendable {
        /// The Feature's name, when the event log still holds it.
        public let name: String?
        /// The Feature Issue's board identifier (e.g. `YLH-360`).
        public let identifier: String
        /// `landed`, `abandoned`, or the Feature's recorded state.
        public let outcome: String

        public init(name: String?, identifier: String, outcome: String) {
            self.name = name
            self.identifier = identifier
            self.outcome = outcome
        }
    }

    /// A Card in Waiting on You.
    public struct WaitingCard: Equatable, Sendable {
        public let identifier: String
        public let title: String
        public let repository: String
        public let reason: String

        public init(identifier: String, title: String, repository: String, reason: String) {
            self.identifier = identifier
            self.title = title
            self.repository = repository
            self.reason = reason
        }
    }

    /// A Feature in the Unmerged Feature Stack U (roadmap P23.2; spec: feature-authoring/select-the-next-feature,
    /// `#effective-base`): implemented and awaiting merge, never to be selected again.
    public struct UnmergedFeature: Equatable, Sendable {
        /// The Feature's name, when the event log still holds it.
        public let name: String?
        /// The Feature Issue's board identifier (e.g. `YLH-360`).
        public let identifier: String
        /// Every repository the Feature's Cycle touches, sorted.
        public let touchedRepositories: [String]
        /// The repositories still awaiting an Observed Merge, sorted, each with its Feature Branch.
        public let unmergedBranches: [UnmergedBranch]

        public init(
            name: String?, identifier: String, touchedRepositories: [String], unmergedBranches: [UnmergedBranch]
        ) {
            self.name = name
            self.identifier = identifier
            self.touchedRepositories = touchedRepositories
            self.unmergedBranches = unmergedBranches
        }
    }

    /// One pushed repository of a Feature in U with no Observed Merge yet, and its Feature Branch.
    public struct UnmergedBranch: Equatable, Sendable {
        public let repository: String
        public let branch: String

        public init(repository: String, branch: String) {
            self.repository = repository
            self.branch = branch
        }
    }

    /// Most recent first.
    public let features: [AuthoredFeature]
    public let waitingCards: [WaitingCard]
    /// U, oldest first (F1…Fm).
    public let unmergedFeatures: [UnmergedFeature]

    public init(
        features: [AuthoredFeature] = [], waitingCards: [WaitingCard] = [], unmergedFeatures: [UnmergedFeature] = []
    ) {
        self.features = features
        self.waitingCards = waitingCards
        self.unmergedFeatures = unmergedFeatures
    }

    public var isEmpty: Bool { features.isEmpty && waitingCards.isEmpty && unmergedFeatures.isEmpty }

    /// The Feature in U whose name equals `name`, trimmed and case-insensitively; nil when none does.
    public func unmergedFeature(named name: String) -> UnmergedFeature? {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return unmergedFeatures.first {
            $0.name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == wanted
        }
    }
}
