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
    /// Every configured Project, in configured order: the order the configuration loader returns, which
    /// is by id. The sponsor was indifferent to this order and delegated it to the lead, and nothing here
    /// re-sorts it. Refused configuration files are not here: the Sidebar omits them, and the Settings
    /// window surfaces them.
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
    /// Why this Project's Journal could not be read, in the Journal's own words. Nil when `pulse` was
    /// read from the Journal, and also when the Project has no Journal yet: no Act of it has run, so the
    /// empty, idle Pulse is true.
    ///
    /// When this is set, `pulse` is empty and says nothing about the Project. A view states this failure
    /// in place of the Pulse, and in place of the `idle`/`working` status.
    public var journalFailure: String?

    public init(id: ProjectID, name: String, repos: [String], pulse: PulseSnapshot, journalFailure: String? = nil) {
        self.id = id
        self.name = name
        self.repos = repos
        self.pulse = pulse
        self.journalFailure = journalFailure
    }

    /// The Sidebar's `idle`/`working`: the same value the Pulse's Now group shows.
    ///
    /// Check `journalFailure` first. When the Journal could not be read, this is the empty Pulse's
    /// `idle`, which is not derived from anything.
    public var status: ProjectStatus { pulse.now.status }

    /// Whether `selection` names something in this Project's own Pulse or Repos. The Inspector shows
    /// only a selection this returns true for, so a Card, Attempt or Repo of another Project never
    /// appears beside this Project's Pulse.
    public func contains(_ selection: PulseSelection) -> Bool {
        switch selection {
        case let .card(id): pulse.needsYou.cards.contains { $0.id == id }
        case let .feature(id): pulse.feature?.id == id
        case let .attempt(id): pulse.now.attempts.contains { $0.id == id }
        case let .repo(repo): repos.contains(repo)
        }
    }

    /// The Repo's `lane_state` while it is `in_lane`; nil otherwise, so no badge shows.
    public func laneState(for repo: String) -> LaneState? {
        pulse.feature?.lanes.first { $0.repo == repo }?.state
    }

    /// The running Attempt nested under this Repo in the Sidebar, shown only while it runs.
    public func runningAttempt(for repo: String) -> RunningAttempt? {
        pulse.now.attempts.first { $0.repo == repo }
    }

    /// The running Attempt with this id, or nil when no Attempt of this Project runs under it.
    public func runningAttempt(id: String) -> RunningAttempt? {
        pulse.now.attempts.first { $0.id == id }
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
