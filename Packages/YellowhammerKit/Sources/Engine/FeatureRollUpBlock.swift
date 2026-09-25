import Domain

/// Renders a ``FeatureRollUp`` as the Feature Issue's Managed Block (roadmap P12.3; spec: board-
/// projection/maintain-the-managed-block, second story): the bold sentence (with any Mainline
/// Conflicts beside it), then the member Cards grouped by Repo Lane, worst-severity lane first, with a
/// trailing `#### Cancelled` group. A zero-Card Feature renders only the sentence line.
public struct FeatureRollUpBlock {
    public let rollUp: FeatureRollUp

    public init(rollUp: FeatureRollUp) {
        self.rollUp = rollUp
    }

    public func render() -> String {
        var lines = ["**\(rollUp.sentence)**\(rollUp.conflictsSuffix)"]
        guard !rollUp.members.isEmpty else {
            return lines.joined(separator: "\n")
        }
        lines.append("")
        lines.append("### Cards")
        lines.append(contentsOf: renderLanes())
        lines.append(contentsOf: renderCancelledGroup())
        return lines.joined(separator: "\n")
    }

    /// Most severe first: a Card Waiting on You holds up a lane worse than a Blocked one, and so on
    /// down to Done. Cancelled never reaches here — cancelled Cards are excluded from every lane.
    private static func severityRank(_ state: CardState) -> Int {
        switch state {
        case .waitingOnYou: 0
        case .blocked: 1
        case .inProgress: 2
        case .todo: 3
        case .done: 4
        case .cancelled: 5
        }
    }

    private func renderLanes() -> [String] {
        let live = rollUp.members.filter { $0.state != .cancelled }
        let byRepository = Dictionary(grouping: live, by: { $0.repository })
        let orderedRepositories = byRepository.keys.sorted { lhs, rhs in
            let lhsSeverity = worstSeverity(byRepository[lhs] ?? [])
            let rhsSeverity = worstSeverity(byRepository[rhs] ?? [])
            return lhsSeverity != rhsSeverity ? lhsSeverity < rhsSeverity : lhs < rhs
        }

        var lines: [String] = []
        for repository in orderedRepositories {
            let cards = sortedBySeverity(byRepository[repository] ?? [])
            lines.append("")
            lines.append("#### `\(repository)` — \(laneStatus(for: cards, repository: repository))")
            lines.append(contentsOf: cards.map(renderCardLine))
        }
        return lines
    }

    private func worstSeverity(_ cards: [RollUpMember]) -> Int {
        cards.map { Self.severityRank($0.state) }.min() ?? Self.severityRank(.done)
    }

    private func sortedBySeverity(_ cards: [RollUpMember]) -> [RollUpMember] {
        cards.sorted { lhs, rhs in
            let lhsRank = Self.severityRank(lhs.state)
            let rhsRank = Self.severityRank(rhs.state)
            return lhsRank != rhsRank ? lhsRank < rhsRank : lhs.authoredOrder < rhs.authoredOrder
        }
    }

    /// "pushed" only for a lane whose own Worktree recorded a push (issue #161 part 2) — `lanesPushed`
    /// alone (the Cycle landed) is Cycle-wide and does not distinguish a rehearsal Night, which lands
    /// but never pushes, or a real lane whose push failed, from one that actually reached the remote.
    private func laneStatus(for cards: [RollUpMember], repository: String) -> String {
        guard !rollUp.pushedRepositories.contains(repository) else { return "pushed" }
        let hasUnfinished = cards.contains { $0.state == .todo || $0.state == .inProgress }
        return hasUnfinished ? "running" : "finished"
    }

    private func renderCardLine(_ card: RollUpMember) -> String {
        "- \(Self.name(card)) — \(card.state.rawValue)\(reasonSuffix(card))\(markerSuffix(card))"
    }

    /// A Card's rendered name (issue #161; spec: landing/announce-a-partial-landing): its title when
    /// the Journal has recorded one, falling back to its backticked issue id otherwise.
    private static func name(_ card: RollUpMember) -> String {
        card.nonEmptyTitle ?? "`\(card.issueID)`"
    }

    private func reasonSuffix(_ card: RollUpMember) -> String {
        if card.state == .blocked, let blockReason = card.blockReason {
            return " (\(blockReason))"
        }
        if card.state == .waitingOnYou, let waitingReason = card.waitingReason {
            return " (\(waitingReason.rawValue))"
        }
        return ""
    }

    /// Adopted first, then banked answer — the order this brief specifies. ``FeatureMemberMarker/cancelled``
    /// is never rendered here: the `#### Cancelled` group it names is the marker.
    private func markerSuffix(_ card: RollUpMember) -> String {
        var suffix = ""
        if let previousFeatureIssueID = card.adoptedFromFeatureIssueID {
            suffix += " · adopted from `\(previousFeatureIssueID)`"
        }
        if card.markers.contains(.bankedAnswer) {
            suffix += " · banked answer waiting"
        }
        return suffix
    }

    private func renderCancelledGroup() -> [String] {
        let cancelled = rollUp.members
            .filter { $0.state == .cancelled }
            .sorted { lhs, rhs in
                lhs.repository != rhs.repository
                    ? lhs.repository < rhs.repository
                    : lhs.authoredOrder < rhs.authoredOrder
            }
        guard !cancelled.isEmpty else { return [] }

        var lines = ["", "#### Cancelled"]
        for card in cancelled {
            lines.append("- \(Self.name(card)) [`\(card.repository)`] — Cancelled\(markerSuffix(card))")
        }
        return lines
    }
}
