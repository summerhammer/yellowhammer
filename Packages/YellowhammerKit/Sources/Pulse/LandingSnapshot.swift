import Domain
import Foundation

// The landing screen's view state (spec: app/land-on-the-sidebar-and-pulse): plain values, and nothing
// that keeps a connection or runs `yh`. A landing-screen view renders these and nothing else, so a
// prototype can feed it fixtures and the shipped screen can feed it a Journal read, with the same view
// in both.
//
// The shape keeps the screen's rulings structural: every Project carries only its own Pulse, and every
// Sidebar value is derived from that one Project's Pulse, so nothing here can blend two Projects' data.
// There is no `paused` or `error` status, no transcript or log tail, and no Trend group.

/// Everything the landing screen shows, as of one instant.
public struct LandingSnapshot: Equatable, Sendable {
    /// Every configured Project, in configured order. Refused configuration files are not here: the
    /// Sidebar omits them, and the Settings window surfaces them.
    public var projects: [ProjectSnapshot]
    /// The instant the snapshot describes. Views format elapsed and relative times against this, never
    /// against the clock, so a preview renders the same every time.
    public var asOf: Date

    public init(projects: [ProjectSnapshot], asOf: Date) {
        self.projects = projects
        self.asOf = asOf
    }

    public func project(_ id: ProjectID?) -> ProjectSnapshot? {
        projects.first { $0.id == id }
    }
}

/// One configured Project: its identity, its Repos, and its own Pulse.
public struct ProjectSnapshot: Identifiable, Equatable, Sendable {
    public let id: ProjectID
    public var name: String
    /// Every configured Repo, in `[repos]` declared order. The Sidebar always shows all of them.
    public var repos: [String]
    public var pulse: PulseSnapshot

    public init(id: ProjectID, name: String, repos: [String], pulse: PulseSnapshot) {
        self.id = id
        self.name = name
        self.repos = repos
        self.pulse = pulse
    }

    /// The Sidebar's `idle`/`working`: the same value the Pulse's Now group shows.
    public var status: ProjectStatus { pulse.now.status }

    /// The Repo's `lane_state` while it is `in_lane`; nil otherwise, so no badge shows.
    public func laneState(for repo: String) -> LaneState? {
        pulse.feature?.lanes.first { $0.repo == repo }?.state
    }

    /// The running Attempt nested under this Repo in the Sidebar, shown only while it runs.
    public func runningAttempt(for repo: String) -> RunningAttempt? {
        pulse.now.attempts.first { $0.repo == repo }
    }
}

/// A Project's derived status. `working` means exactly that the Project's `launchd` Act job is alive.
public enum ProjectStatus: String, CaseIterable, Sendable {
    case idle
    case working
}

/// A Repo Lane's state as a Sidebar badge and a Feature-group lane shows it. The spec lists these as
/// examples ("e.g. running / blocked / waiting on you / landed"), so the set is draft, not closed.
public enum LaneState: String, CaseIterable, Sendable {
    case running
    case blocked
    case waitingOnYou = "waiting on you"
    case landed
}
