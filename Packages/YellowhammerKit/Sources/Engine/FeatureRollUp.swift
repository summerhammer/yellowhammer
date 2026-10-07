import Domain
import Journal

/// Which Authoring stop a zero-Card Feature Issue is sitting on (glossary → Refusal, Authoring Halt).
/// The word "refusal" must never be rendered for a halt, so ``FeatureIssueStanding`` carries this kind
/// rather than a single boolean, making the two structurally distinct at every call site.
public enum AuthoringStopKind: Sendable {
    case refusal
    case halt

    fileprivate var zeroCardWord: String {
        switch self {
        case .refusal: "refusal"
        case .halt: "halt"
        }
    }
}

/// The zero-Card Feature Issue's own state, read only when a Feature has no member Cards at all — the
/// Roll-up falls back to it. A Feature with zero Cards never renders `verified`.
public enum FeatureIssueStanding: Sendable {
    case authoring
    case awaitingYou(AuthoringStopKind)
    case unanswered(AuthoringStopKind)
}

/// One member Card as the Roll-up needs to see it: enough to place it in the lattice and to render its
/// row in the Managed Block, without requiring a full Journal `CardRecord` in a pure unit test.
public struct RollUpMember: Equatable, Sendable {
    public var issueID: String
    /// The board's title for this Card, nil when the Journal has not recorded one yet. The Managed
    /// Block names this Card by title when present, falling back to its backticked issue id otherwise.
    public var title: String?
    public var repository: String
    public var authoredOrder: Int
    public var state: CardState
    public var waitingReason: WaitingReason?
    public var blockReason: String?
    /// Read-time markers (roadmap P11.3) — only ``FeatureMemberMarker/bankedAnswer`` is rendered here;
    /// ``FeatureMemberMarker/shelved`` is redundant with `state` and is not consulted.
    public var markers: Set<FeatureMemberMarker>
    /// The previous Feature Issue this Card was adopted from, nil when not adopted. Carried separately
    /// from `markers` because it holds data (roadmap P12.3).
    public var adoptedFromFeatureIssueID: String?

    public init(
        issueID: String,
        title: String? = nil,
        repository: String,
        authoredOrder: Int,
        state: CardState,
        waitingReason: WaitingReason? = nil,
        blockReason: String? = nil,
        markers: Set<FeatureMemberMarker> = [],
        adoptedFromFeatureIssueID: String? = nil
    ) {
        self.issueID = issueID
        self.title = title
        self.repository = repository
        self.authoredOrder = authoredOrder
        self.state = state
        self.waitingReason = waitingReason
        self.blockReason = blockReason
        self.markers = markers
        self.adoptedFromFeatureIssueID = adoptedFromFeatureIssueID
    }

    /// This Card's title, or nil when the Journal has not recorded a non-empty one — the caller falls
    /// back to the backticked issue id.
    public var nonEmptyTitle: String? {
        guard let title, !title.isEmpty else { return nil }
        return title
    }
}

/// A Feature's derived Roll-up (glossary → Roll-up; spec: board-projection/maintain-the-managed-block,
/// second story): a pure value over its member Cards, computed once at init so `state`, `sentence` and
/// `conflictsSuffix` are always in agreement with the inputs that produced them.
public struct FeatureRollUp: Sendable {
    public let members: [RollUpMember]
    /// Whether every Repo Lane has finished — the Cycle has landed. This selects the closed half of
    /// the lattice; it says nothing about whether any lane's push succeeded (a rehearsal Night lands
    /// but never pushes, and a real lane's push can fail) — that is ``pushedRepositories``.
    public let lanesPushed: Bool
    public let verificationPassed: Bool
    /// Unmet or unresolved clauses in the recorded Verification; nil means no record exists.
    public let unmetClauseCount: Int?
    public let mergedFraction: MergedFraction
    public let conflictingRepositories: [String]
    /// The repositories with a No-Pushed-Branch Outcome (roadmap P19.7; risks OQ108): each is shown as a
    /// `[no pull request: <repo>]` note beside the sentence, never inside it.
    public let noPullRequestRepositories: [String]
    /// The repositories whose lane actually pushed (issue #161 part 2): a lane's own
    /// `#### \`repo\` — pushed` heading is true of this set, never of `lanesPushed` alone, which is
    /// Cycle-wide, not per-lane.
    public let pushedRepositories: Set<String>
    public let issueStanding: FeatureIssueStanding

    /// The word, or nil ("absent") when every member Card is Shelved.
    public let state: RollUpState?
    /// The rendered sentence, without the bold markdown and without the conflicts or no-pull-request suffixes.
    public let sentence: String
    /// ` [conflict: <repo>] [conflict: <repo>]…`, sorted by repository name; empty when there are none.
    /// Rendered beside the sentence, never inside it — it never changes `state` or any slot.
    public let conflictsSuffix: String
    /// ` [no pull request: <repo>]…`, sorted by repository name; empty when there are none. Rendered
    /// beside the sentence after ``conflictsSuffix``, never inside it (roadmap P19.7; risks OQ108).
    public let noPullRequestSuffix: String

    public init(
        members: [RollUpMember],
        lanesPushed: Bool,
        verificationPassed: Bool,
        unmetClauseCount: Int? = nil,
        mergedFraction: MergedFraction,
        conflictingRepositories: [String] = [],
        noPullRequestRepositories: [String] = [],
        pushedRepositories: Set<String> = [],
        issueStanding: FeatureIssueStanding
    ) {
        self.members = members
        self.lanesPushed = lanesPushed
        self.verificationPassed = verificationPassed
        self.unmetClauseCount = unmetClauseCount
        self.mergedFraction = mergedFraction
        self.conflictingRepositories = conflictingRepositories
        self.noPullRequestRepositories = noPullRequestRepositories
        self.pushedRepositories = pushedRepositories
        self.issueStanding = issueStanding

        let (state, sentence) = Self.compute(
            members: members, lanesPushed: lanesPushed,
            verification: (verificationPassed, unmetClauseCount),
            mergedFraction: mergedFraction, issueStanding: issueStanding
        )
        self.state = state
        self.sentence = sentence
        self.conflictsSuffix = Self.conflictsSuffix(conflictingRepositories)
        self.noPullRequestSuffix = noPullRequestRepositories.isEmpty
            ? "" : " " + Self.noPullRequestNotes(noPullRequestRepositories)
    }

    /// `[no pull request: <repo>] [no pull request: <repo>]…`, sorted by repository name, no leading
    /// space — the one place this note is spelled, shared by the Managed Block, the Night Summary's
    /// standing line and a pull request body (roadmap P19.7; risks OQ108).
    public static func noPullRequestNotes(_ repositories: [String]) -> String {
        repositories.sorted().map { "[no pull request: \($0)]" }.joined(separator: " ")
    }

    private static func compute(
        members: [RollUpMember], lanesPushed: Bool,
        verification: (passed: Bool, unmetClauseCount: Int?),
        mergedFraction: MergedFraction, issueStanding: FeatureIssueStanding
    ) -> (RollUpState?, String) {
        guard !members.isEmpty else {
            return zeroCard(issueStanding)
        }
        let live = members.filter { $0.state != .shelved }
        guard !live.isEmpty else {
            return (nil, "no live Cards · \(members.count) shelved")
        }
        return lanesPushed
            ? closedHalf(live: live, verificationPassed: verification.passed,
                         unmetClauseCount: verification.unmetClauseCount, mergedFraction: mergedFraction)
            : runningHalf(live: live)
    }

    private static func zeroCard(_ standing: FeatureIssueStanding) -> (RollUpState?, String) {
        switch standing {
        case .authoring:
            (.authoring, "authoring · no Cards yet · in authoring")
        case .awaitingYou(let kind):
            (.waiting, "waiting · no Cards yet · \(kind.zeroCardWord) awaiting you")
        case .unanswered(let kind):
            (.blocked, "blocked · no Cards yet · \(kind == .halt ? "halt overdue" : "reply overdue")")
        }
    }

    private static func runningHalf(live: [RollUpMember]) -> (RollUpState?, String) {
        let liveCount = live.count
        let doneCount = live.count { $0.state == .done }
        let waitingCount = live.count { $0.state == .waitingOnYou }
        let blockedCount = live.count { $0.state == .blocked }
        let inProgressCount = live.count { $0.state == .inProgress }

        let word: RollUpState = waitingCount > 0 ? .waiting : (blockedCount > 0 ? .blocked : .running)
        let top: String
        if waitingCount > 0 {
            top = "\(waitingCount) waiting on you"
        } else if blockedCount > 0 {
            top = "\(blockedCount) blocked"
        } else if inProgressCount > 0 {
            top = "\(inProgressCount) running"
        } else {
            top = "all on track"
        }
        return (word, "\(word.rawValue) · \(doneCount) of \(liveCount) Cards landed · \(top)")
    }

    private static func closedHalf(
        live: [RollUpMember], verificationPassed: Bool, unmetClauseCount: Int?, mergedFraction: MergedFraction
    ) -> (RollUpState?, String) {
        let liveCount = live.count
        let doneCount = live.count { $0.state == .done }
        let waitingCount = live.count { $0.state == .waitingOnYou }
        let blockedCount = live.count { $0.state == .blocked }
        let allDone = live.allSatisfy { $0.state == .done }

        let word: RollUpState
        let top: String
        if waitingCount > 0 {
            word = .partial
            top = "\(waitingCount) waiting on you"
        } else if blockedCount > 0 {
            word = .partial
            top = "\(blockedCount) blocked"
        } else if allDone && verificationPassed {
            word = .verified
            top = "all verified"
        } else {
            // All Done without passing Verification is a Feature-level waiting disposition,
            // not a Partial Landing: no live member is Blocked or Waiting on You.
            word = .waiting
            top = unmetClauseCount.map { "\($0) clauses unmet" } ?? "verification not recorded"
        }

        var slots = ["\(word.rawValue)", "\(doneCount) of \(liveCount) Cards landed"]
        if !mergedFraction.isFullyMerged {
            slots.append(mergedFraction.formatted)
        }
        slots.append(top)
        return (word, slots.joined(separator: " · "))
    }

    private static func conflictsSuffix(_ repositories: [String]) -> String {
        guard !repositories.isEmpty else { return "" }
        return " " + repositories.sorted().map { "[conflict: \($0)]" }.joined(separator: " ")
    }
}
