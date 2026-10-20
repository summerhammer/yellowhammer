import Domain
import Journal

/// Renders a ``FeatureRollUp`` as the Feature Issue's Managed Block (roadmap P12.3; spec: board-
/// projection/maintain-the-managed-block, second story): the bold sentence (with any Mainline
/// Conflicts, then any No-Pushed-Branch Outcomes, beside it), then the member Cards grouped by Repo
/// Lane, worst-severity lane first, with a trailing `#### Shelved` group. A zero-Card Feature renders only the sentence line.
public struct FeatureRollUpBlock {
    public let rollUp: FeatureRollUp

    public init(rollUp: FeatureRollUp) {
        self.rollUp = rollUp
    }

    /// The block as the Feature Issue's later rewrites can render it at its largest for these members, so a
    /// description can be measured at authoring against the room those rewrites need. Each member takes the
    /// longest closed-vocabulary state, reason and marker wording its line can have (a Blocked Card with the
    /// longest Block Reason, a Waiting on You Card with the longest Waiting Reason, a banked answer, and
    /// "adopted from" for an adopted Card), with the longest of the running and closed sentences and a
    /// conflict and a no-pull-request note for every repository. `prototypes` supply each member's title,
    /// issue id, repository and adoption; their state is replaced. Free text it cannot know is left out: a
    /// title the board later gives a Card that has none here, and the issue id Linear will assign to a
    /// new Card (its drafted title stands in for it, as the block names a titled Card by title).
    public static func largestRendering(of prototypes: [RollUpMember], repositories: [String]) -> String {
        let members = prototypes.map { longestMember($0) }
        var candidates = [false, true].map { lanesPushed in
            FeatureRollUpBlock(rollUp: FeatureRollUp(
                members: members, lanesPushed: lanesPushed, verificationPassed: false,
                unmetClauseCount: members.count,
                notCheckedClauseCount: members.count,
                mergedFraction: MergedFraction(mergedCount: 0, totalCount: repositories.count),
                conflictingRepositories: repositories, noPullRequestRepositories: repositories,
                issueStanding: .authoring
            )).render()
        }
        // The longest member lines are blocked or waiting, which mask Verification's longer
        // closed-half slot. Measure that slot with Done members, keeping the longest member lines
        // underneath it: the description budget must cover both independently.
        let done = members.map { member in
            var member = member
            member.state = .done
            return member
        }
        let verification = FeatureRollUp(
            members: done, lanesPushed: true, verificationPassed: false,
            unmetClauseCount: members.count, notCheckedClauseCount: members.count,
            mergedFraction: MergedFraction(mergedCount: 0, totalCount: repositories.count),
            conflictingRepositories: repositories, noPullRequestRepositories: repositories,
            issueStanding: .authoring
        )
        if let longest = candidates.max(by: { $0.count < $1.count }) {
            let lines = longest.split(separator: "\n", omittingEmptySubsequences: false).dropFirst()
            candidates.append(
                (["**\(verification.sentence)**\(verification.conflictsSuffix)\(verification.noPullRequestSuffix)"]
                    + lines.map(String.init)).joined(separator: "\n")
            )
        }
        return candidates.max { $0.count < $1.count } ?? ""
    }

    private static func longestMember(_ prototype: RollUpMember) -> RollUpMember {
        var variants: [RollUpMember] = []
        for state in CardState.allCases {
            var member = prototype
            member.state = state
            member.waitingReason = nil
            member.blockReason = nil
            member.markers = [.bankedAnswer]
            switch state {
            case .blocked:
                variants += BlockReason.allCases.map { reason in
                    var blocked = member
                    blocked.blockReason = reason.rawValue
                    return blocked
                }
            case .waitingOnYou:
                variants += WaitingReason.allCases.map { reason in
                    var waiting = member
                    waiting.waitingReason = reason
                    return waiting
                }
            default:
                variants.append(member)
            }
        }
        func size(_ member: RollUpMember) -> Int {
            FeatureRollUpBlock(rollUp: FeatureRollUp(
                members: [member], lanesPushed: false, verificationPassed: false,
                mergedFraction: MergedFraction(mergedCount: 0, totalCount: 1), issueStanding: .authoring
            )).render().count
        }
        return variants.max { size($0) < size($1) } ?? prototype
    }

    public func render() -> String {
        var lines = ["**\(rollUp.sentence)**\(rollUp.conflictsSuffix)\(rollUp.noPullRequestSuffix)"]
        guard !rollUp.members.isEmpty else {
            return lines.joined(separator: "\n")
        }
        lines.append("")
        lines.append("### Cards")
        lines.append(contentsOf: renderLanes())
        lines.append(contentsOf: renderShelvedGroup())
        return lines.joined(separator: "\n")
    }

    /// Most severe first: a Card Waiting on You holds up a lane worse than a Blocked one, and so on
    /// down to Done. Shelved never reaches here — shelved Cards are excluded from every lane.
    private static func severityRank(_ state: CardState) -> Int {
        switch state {
        case .waitingOnYou: 0
        case .blocked: 1
        case .inProgress: 2
        case .todo: 3
        case .done: 4
        case .shelved: 5
        }
    }

    private func renderLanes() -> [String] {
        let live = rollUp.members.filter { $0.state != .shelved }
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
            let next = BlockReason(rawValue: blockReason).map { " · next: \($0.nextAction)" } ?? ""
            return " (\(blockReason))\(next)"
        }
        if card.state == .waitingOnYou, let waitingReason = card.waitingReason {
            return " (\(waitingReason.rawValue))"
        }
        return ""
    }

    /// Adopted first, then banked answer — the order this brief specifies. ``FeatureMemberMarker/shelved``
    /// is never rendered here: the `#### Shelved` group it names is the marker.
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

    private func renderShelvedGroup() -> [String] {
        let shelved = rollUp.members
            .filter { $0.state == .shelved }
            .sorted { lhs, rhs in
                lhs.repository != rhs.repository
                    ? lhs.repository < rhs.repository
                    : lhs.authoredOrder < rhs.authoredOrder
            }
        guard !shelved.isEmpty else { return [] }

        var lines = ["", "#### Shelved"]
        for card in shelved {
            lines.append("- \(Self.name(card)) [`\(card.repository)`] — Shelved\(markerSuffix(card))")
        }
        return lines
    }
}
