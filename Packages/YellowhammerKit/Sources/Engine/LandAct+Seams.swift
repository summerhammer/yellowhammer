import Domain
import Journal

// The land Act's injectable seams (roadmap P10.1), split out of LandAct.swift to keep that file under
// the file length limit. Every seam is optional: nil means the roadmap phase that fills it has not
// landed yet, and the step it would have run is recorded `.notWired` instead. None of these is named
// after a Port (ADR-001) — a later phase's adapter sits behind the Port names (Publication, Dispatch),
// not behind these.

/// One Repo Lane's context, handed to its three per-lane seams.
public struct LandActLaneContext: Sendable {
    public let act: ActContext
    public let feature: FeatureRecord
    public let cycleID: Int64
    public let lane: RepoLane

    public init(act: ActContext, feature: FeatureRecord, cycleID: Int64, lane: RepoLane) {
        self.act = act
        self.feature = feature
        self.cycleID = cycleID
        self.lane = lane
    }
}

/// What a Repo Lane's merge test (P10.3) reported. Never gates landing: whatever it reports, landing
/// proceeds.
public struct MergeTestOutcome: Equatable, Sendable {
    /// Whether the Feature Branch would not merge cleanly into mainline — a Mainline Conflict.
    public let conflict: Bool
    public let detail: String?

    public init(conflict: Bool, detail: String? = nil) {
        self.conflict = conflict
        self.detail = detail
    }
}

/// Tests whether a Repo Lane's Feature Branch merges cleanly into mainline (P10.3).
public protocol LaneMergeTesting: Sendable {
    func test(_ context: LandActLaneContext) async throws -> MergeTestOutcome
}

/// What a Repo Lane's push (P10.2) reported. A push failure is a first-class outcome, not a throw.
public struct LanePushOutcome: Equatable, Sendable {
    public let pushed: Bool
    /// The pushed commit, set only when `pushed` is true.
    public let commit: String?
    /// Why the push did not happen, set only when `pushed` is false.
    public let reason: String?

    public init(pushed: Bool, commit: String? = nil, reason: String? = nil) {
        self.pushed = pushed
        self.commit = commit
        self.reason = reason
    }
}

/// Pushes a Repo Lane's Feature Branch (P10.2). Never called in rehearsal mode (a rehearsal boundary).
public protocol LanePushing: Sendable {
    func push(_ context: LandActLaneContext) async throws -> LanePushOutcome
}

/// What opening a Repo Lane's pull request (P10.4) reported.
public struct PullRequestOutcome: Equatable, Sendable {
    public let opened: Bool
    public let detail: String?

    public init(opened: Bool, detail: String? = nil) {
        self.opened = opened
        self.detail = detail
    }
}

/// Opens a Repo Lane's pull request (P10.4), only once its push reported pushed. Never called in
/// rehearsal mode (a rehearsal boundary).
public protocol PullRequestOpening: Sendable {
    func open(_ context: LandActLaneContext, push: LanePushOutcome) async throws -> PullRequestOutcome
}

/// The Feature's context, handed to its three Feature-scoped seams.
public struct LandActFeatureContext: Sendable {
    public let act: ActContext
    public let feature: FeatureRecord
    public let cycleID: Int64

    public init(act: ActContext, feature: FeatureRecord, cycleID: Int64) {
        self.act = act
        self.feature = feature
        self.cycleID = cycleID
    }
}

/// A two-way Verification verdict (P10.5): every Definition of Done clause met, or unmet clauses present.
public struct VerificationVerdict: Equatable, Sendable {
    public let allClausesMet: Bool
    public let unmetClauses: [String]

    public init(allClausesMet: Bool, unmetClauses: [String] = []) {
        self.allClausesMet = allClausesMet
        self.unmetClauses = unmetClauses
    }
}

/// Runs Verification over the landed Feature (P10.5).
public protocol FeatureVerifying: Sendable {
    func verify(_ context: LandActFeatureContext) async throws -> VerificationVerdict
}

/// Returns the Feature for unmet clauses (P10.6), called only when Verification's verdict is unmet.
public protocol FeatureReturning: Sendable {
    func returnFeature(_ context: LandActFeatureContext, verdict: VerificationVerdict) async throws
}

/// Archives the Feature's Cycle (P10.7), called only when Verification's verdict is all-met.
public protocol CycleArchiving: Sendable {
    func archive(_ context: LandActFeatureContext) async throws
}
