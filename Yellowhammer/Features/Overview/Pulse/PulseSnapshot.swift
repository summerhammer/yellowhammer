import Domain
import Foundation
import SwiftUI

// The landing screen's view state (spec: app/land-on-the-sidebar-and-pulse): plain values, and nothing
// that reads a Journal, runs `yh` or keeps a connection. A landing-screen view renders these and nothing
// else, so a prototype can feed it fixtures and the shipped screen can feed it a Journal read, with the
// same view in both.
//
// The shape keeps the screen's rulings structural: every Project carries only its own Pulse, and every
// Sidebar value is derived from that one Project's Pulse, so nothing here can blend two Projects' data.
// There is no `paused` or `error` status, no transcript or log tail, and no Trend group.

/// Everything the landing screen shows, as of one instant.
struct LandingSnapshot: Equatable {
    /// Every configured Project, in configured order. Refused configuration files are not here: the
    /// Sidebar omits them, and the Settings window surfaces them.
    var projects: [ProjectSnapshot]
    /// The instant the snapshot describes. Views format elapsed and relative times against this, never
    /// against the clock, so a preview renders the same every time.
    var asOf: Date

    func project(_ id: ProjectID?) -> ProjectSnapshot? {
        projects.first { $0.id == id }
    }
}

/// One configured Project: its identity, its Repos, and its own Pulse.
struct ProjectSnapshot: Identifiable, Equatable {
    let id: ProjectID
    var name: String
    /// Every configured Repo, in `[repos]` declared order. The Sidebar always shows all of them.
    var repos: [String]
    var pulse: PulseSnapshot

    /// The Sidebar's `idle`/`working`: the same value the Pulse's Now group shows.
    var status: ProjectStatus { pulse.now.status }

    /// The Repo's `lane_state` while it is `in_lane`; nil otherwise, so no badge shows.
    func laneState(for repo: String) -> LaneState? {
        pulse.feature?.lanes.first { $0.repo == repo }?.state
    }

    /// The running Attempt nested under this Repo in the Sidebar, shown only while it runs.
    func runningAttempt(for repo: String) -> RunningAttempt? {
        pulse.now.attempts.first { $0.repo == repo }
    }
}

/// A Project's derived status. `working` means exactly that the Project's `launchd` Act job is alive.
enum ProjectStatus: String, CaseIterable, Sendable {
    case idle
    case working
}

/// A Repo Lane's state as a Sidebar badge and a Feature-group lane shows it. The spec lists these as
/// examples ("e.g. running / blocked / waiting on you / landed"), so the set is draft, not closed.
enum LaneState: String, CaseIterable, Sendable {
    case running
    case blocked
    case waitingOnYou = "waiting on you"
    case landed
}

// MARK: - Pulse

/// One Project's Pulse, in the ruled order: Needs you → Now → Feature → Tonight / last Night → Health.
struct PulseSnapshot: Equatable {
    var needsYou: NeedsYou
    var now: Now
    /// The in-flight Feature; nil when there is none, and the group states that absence.
    var feature: FeatureInFlight?
    /// The running Night, else the last one; nil when this Project has had no Night yet.
    var night: NightPulse?
    /// `yh doctor` flags; empty when doctor raised none.
    var health: [HealthFlag]
}

/// Needs you: the Project's decision Cards, Blocked and Waiting on You alike.
struct NeedsYou: Equatable {
    var cards: [DecisionCard]

    var waitingOnYouCount: Int {
        cards.count { $0.state == .waitingOnYou }
    }

    /// Blocked Cards counted by Block Reason, most frequent first.
    var blockReasonCounts: [(reason: BlockReason, count: Int)] {
        let reasons = cards.compactMap(\.blockReason)
        return BlockReason.allCases
            .compactMap { reason in
                let tally = reasons.count { $0 == reason }
                return tally > 0 ? (reason: reason, count: tally) : nil
            }
            .sorted { $0.count > $1.count }
    }
}

/// A Card that needs a decision, opened in one hop into the Inspector.
struct DecisionCard: Identifiable, Equatable {
    /// The Linear issue identifier, e.g. `YH-142`.
    let id: String
    var title: String
    /// `.blocked` or `.waitingOnYou`.
    var state: CardState
    /// Set only when `state` is `.blocked`.
    var blockReason: BlockReason?
    var repo: String
}

/// Now: status, next scheduled Act, and running Attempts with a one-line status each.
struct Now: Equatable {
    var status: ProjectStatus
    var nextAct: ScheduledAct?
    var attempts: [RunningAttempt]
}

struct ScheduledAct: Equatable {
    var act: Act
    var at: Date
}

/// A running Attempt. `status` is one line of status, never output from the agent CLI.
struct RunningAttempt: Identifiable, Equatable {
    let id: String
    var cardID: String
    var cardTitle: String
    var repo: String
    /// The route `(cli, model, effort)`, rendered as `Route.description` renders it.
    var route: String
    var startedAt: Date
    /// 1-based; a review asking for changes starts a new Round.
    var round: Int
    var status: String
}

/// Feature: the in-flight Feature, its `rollup_state`, and its Repo Lanes.
struct FeatureInFlight: Equatable {
    /// The Feature Issue's Linear identifier.
    let id: String
    var title: String
    /// The Feature Issue's Linear workflow state.
    var state: String
    var rollupState: RollUpState
    var lanes: [RepoLaneSnapshot]
}

struct RepoLaneSnapshot: Identifiable, Equatable {
    var repo: String
    var state: LaneState
    var cardsDone: Int
    var cardsTotal: Int
    /// The lane's pull request chip; nil until the land Act opens one.
    var pullRequest: PullRequestChip?

    var id: String { repo }
}

struct PullRequestChip: Equatable {
    var number: Int
    var state: PullRequestState
}

enum PullRequestState: String, CaseIterable, Sendable {
    case open
    case draft
    case merged
    case closed
}

/// Tonight / last Night: `verdict_line`, `cards_by_disposition` counts, and Night state.
struct NightPulse: Equatable {
    var state: NightPulseState
    var startedAt: Date
    var verdictLine: String
    /// Cards counted by disposition, in display order; zero counts are omitted.
    var cardsByDisposition: [DispositionCount]
}

enum NightPulseState: String, CaseIterable, Sendable {
    case running
    case done
    case starved
}

struct DispositionCount: Identifiable, Equatable {
    var disposition: CardState
    var count: Int

    var id: CardState { disposition }
}

/// One `yh doctor` flag the Health group shows.
struct HealthFlag: Identifiable, Equatable {
    var kind: HealthFlagKind
    var detail: String

    var id: HealthFlagKind { kind }
}

enum HealthFlagKind: String, CaseIterable, Sendable {
    case staleOperatorIdentity = "stale Operator identity"
    case appInstallationRevoked = "App Installation revoked"
    case probeFailure = "probe failure"
}

// MARK: - Selection and ways out

/// What the Inspector shows. Selecting one of these opens its detail beside the Pulse, never as a
/// pushed screen.
enum PulseSelection: Hashable {
    case card(String)
    case feature(String)
    case attempt(String)
    case repo(String)
}

/// Where a Pulse element leads. None of these is a triage gesture: each opens something, and the
/// gesture itself stays in Linear or GitHub.
enum PulseDestination: Hashable {
    case inspector(PulseSelection)
    case nightCard
    case settings
    case pullRequest(repo: String, number: Int)
    case linearIssue(String)
}

extension EnvironmentValues {
    /// Opens a Pulse element's destination. A landing-screen view calls this instead of opening
    /// anything itself, so the prototype harness can record each way out and the shipped screen can
    /// route it.
    @Entry var openPulseDestination: @MainActor (PulseDestination) -> Void = { _ in }
}
