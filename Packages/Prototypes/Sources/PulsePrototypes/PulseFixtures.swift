#if DEBUG
import Domain
import Pulse
import Foundation

// Fake landing-screen data for prototyping the Pulse in Xcode Previews. Debug builds only: none of
// this ships. Every value is invented; nothing here reads a Journal or configuration.

/// A named program state to prototype against. Each builds a whole ``LandingSnapshot`` of three
/// Projects, so the Sidebar is realistic whichever Project is selected.
enum PulseScenario: String, CaseIterable, Identifiable, CustomStringConvertible {
    case noNightYet = "No Night yet"
    case quietIdle = "Quiet, idle"
    case nightRunning = "Night running"
    case morningTriage = "Morning triage"
    case partialLanding = "Partial Landing"
    case healthFlags = "Health flags"
    case starvedNight = "Starved Night"
    case stress = "Stress: long and many"

    var id: Self { self }
    var description: String { rawValue }

    /// The Project each scenario is about; the other two are background for the Sidebar.
    var focus: ProjectID { PulseFixtures.yellowhammer }

    var snapshot: LandingSnapshot {
        LandingSnapshot(
            projects: [focusProject, PulseFixtures.kestrel(), PulseFixtures.ledgerline()],
            asOf: PulseFixtures.asOf
        )
    }

    private var focusProject: ProjectSnapshot {
        var project = PulseFixtures.yellowhammerProject()
        var pulse = PulseFixtures.quietPulse
        switch self {
        case .noNightYet:
            pulse.night = nil
            pulse.feature = nil
        case .quietIdle:
            break
        case .nightRunning:
            pulse = PulseFixtures.runningPulse
        case .morningTriage:
            pulse.setWaitingOnYou(2)
            pulse.setBlocked(3)
            pulse.feature = PulseFixtures.feature(rollup: .waiting)
            pulse.night = PulseFixtures.night(
                .done,
                verdict: "advanced — 6 Cards done, 5 need you",
                dispositions: [
                    .init(disposition: .done, count: 6), .init(disposition: .blocked, count: 3),
                    .init(disposition: .waitingOnYou, count: 2)
                ]
            )
        case .partialLanding:
            pulse.setBlocked(1)
            pulse.feature = PulseFixtures.partialLandingFeature
            pulse.night = PulseFixtures.night(.done, verdict: "landed partially — 1 of 2 Repos")
        case .healthFlags:
            pulse.setAllHealthFlags(true)
        case .starvedNight:
            pulse.night = PulseFixtures.night(.starved)
        case .stress:
            project.name = "Yellowhammer Engine and Companion Site Monorepo Migration"
            project.repos = PulseFixtures.manyRepos
            pulse = PulseFixtures.runningPulse
            pulse.setWaitingOnYou(5)
            pulse.setBlocked(7)
            pulse.setAttempts(4, across: project.repos)
            pulse.feature = PulseFixtures.feature(rollup: .running, repos: project.repos)
            pulse.setAllHealthFlags(true)
        }
        project.pulse = pulse
        return project
    }
}

/// The building blocks the scenarios and the playground's controls share.
enum PulseFixtures {
    static let yellowhammer = id("yellowhammer")
    static let kestrelID = id("kestrel")
    static let ledgerlineID = id("ledgerline")

    /// A fixture's literal id. An invalid literal is a typo in this file, so it traps.
    private static func id(_ rawValue: String) -> ProjectID {
        guard let id = ProjectID(rawValue: rawValue) else { preconditionFailure("Invalid fixture id \(rawValue)") }
        return id
    }

    /// A fixture's literal URL. An invalid literal is a typo in this file, so it traps.
    private static func url(_ text: String) -> URL {
        guard let url = URL(string: text) else { preconditionFailure("Invalid fixture URL \(text)") }
        return url
    }

    /// A Linear issue's link, as the Journal records one: its identifier and the URL Linear gave.
    static func issueLink(_ identifier: String) -> LinearIssueLink {
        LinearIssueLink(identifier: identifier, url: url("https://linear.app/acme/issue/\(identifier)"))
    }

    /// A pull request chip whose URL is the one GitHub would give.
    static func pullRequest(repo: String, number: Int, state: PullRequestState?) -> PullRequestChip {
        PullRequestChip(number: number, url: url("https://github.com/acme/\(repo)/pull/\(number)"), state: state)
    }

    /// 07:30 local on 2026-09-29: the morning after a Night.
    static let asOf: Date = {
        let components = DateComponents(year: 2026, month: 9, day: 29, hour: 7, minute: 30)
        return Calendar.current.date(from: components) ?? Date(timeIntervalSinceReferenceDate: 0)
    }()

    static func time(_ hour: Int, _ minute: Int, daysFromAsOf days: Int = 0) -> Date {
        let day = Calendar.current.date(byAdding: .day, value: days, to: asOf) ?? asOf
        return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }

    static func minutesBeforeAsOf(_ minutes: Int) -> Date {
        asOf.addingTimeInterval(TimeInterval(-minutes * 60))
    }

    static let defaultRepos = ["yellowhammer", "yellowhammer-site"]
    static let manyRepos = [
        "yellowhammer", "yellowhammer-site", "yellowhammer-release-tooling-and-notarization-scripts",
        "orca-fixtures", "linear-sandbox", "docs"
    ]

    // MARK: Projects

    static func yellowhammerProject() -> ProjectSnapshot {
        ProjectSnapshot(id: yellowhammer, name: "Yellowhammer", repos: defaultRepos, pulse: quietPulse)
    }

    /// A second Project mid-Night, so the Sidebar shows a working row and a lane badge.
    static func kestrel() -> ProjectSnapshot {
        var pulse = runningPulse
        pulse.setAttempts(1, across: ["kestrel-api"])
        pulse.feature = feature(rollup: .running, repos: ["kestrel-api", "kestrel-ios"])
        return ProjectSnapshot(
            id: kestrelID, name: "Kestrel", repos: ["kestrel-ios", "kestrel-api", "kestrel-web"], pulse: pulse
        )
    }

    /// A third Project, idle, one Repo.
    static func ledgerline() -> ProjectSnapshot {
        var pulse = quietPulse
        pulse.feature = nil
        return ProjectSnapshot(id: ledgerlineID, name: "Ledgerline", repos: ["ledgerline"], pulse: pulse)
    }

    // MARK: Pulses

    static let quietPulse = PulseSnapshot(
        needsYou: NeedsYou(cards: []),
        now: Now(status: .idle, nextAct: ScheduledAct(act: .author, at: time(1, 30, daysFromAsOf: 1)), attempts: []),
        feature: nil,
        night: night(.done, verdict: "did not advance — idle"),
        health: []
    )

    static let runningPulse: PulseSnapshot = {
        var pulse = PulseSnapshot(
            needsYou: NeedsYou(cards: []),
            now: Now(
                status: .working, nextAct: ScheduledAct(act: .land, at: time(6, 0, daysFromAsOf: 1)), attempts: []
            ),
            feature: feature(rollup: .running),
            night: night(.running),
            health: []
        )
        pulse.setAttempts(2, across: defaultRepos)
        return pulse
    }()

    // MARK: Feature

    static func feature(rollup: RollUpState, repos: [String] = defaultRepos) -> FeatureInFlight {
        let laneState: LaneState = switch rollup {
        case .authoring, .running: .running
        case .waiting: .waitingOnYou
        case .blocked, .partial: .blocked
        case .verified: .landed
        }
        let lanes = repos.enumerated().map { index, repo in
            RepoLaneSnapshot(
                repo: repo,
                state: index == 0 ? laneState : .running,
                cardsDone: index + 1,
                cardsTotal: index + 4,
                pullRequest: rollup == .verified ? pullRequest(repo: repo, number: 210 + index, state: .merged) : nil
            )
        }
        return FeatureInFlight(
            id: "YH-120",
            title: "Recalibrate the Routing Table from the last seven Nights",
            state: rollup == .authoring ? "Todo" : "In Progress",
            rollupState: rollup,
            lanes: rollup == .authoring ? [] : lanes,
            link: issueLink("YH-120")
        )
    }

    static let partialLandingFeature = FeatureInFlight(
        id: "YH-120",
        title: "Recalibrate the Routing Table from the last seven Nights",
        state: "In Progress",
        rollupState: .partial,
        lanes: [
            RepoLaneSnapshot(
                repo: "yellowhammer", state: .landed, cardsDone: 5, cardsTotal: 5,
                pullRequest: pullRequest(repo: "yellowhammer", number: 214, state: .open)
            ),
            RepoLaneSnapshot(
                repo: "yellowhammer-site", state: .blocked, cardsDone: 1, cardsTotal: 3,
                pullRequest: pullRequest(repo: "yellowhammer-site", number: 88, state: .draft)
            )
        ],
        link: issueLink("YH-120")
    )

    // MARK: Night

    static func night(
        _ state: NightPulseState,
        verdict: String? = nil,
        dispositions: [DispositionCount]? = nil
    ) -> NightPulse {
        let defaultDispositions: [DispositionCount] = switch state {
        case .running:
            [.init(disposition: .done, count: 2), .init(disposition: .inProgress, count: 2),
             .init(disposition: .todo, count: 3)]
        case .done:
            [.init(disposition: .done, count: 6), .init(disposition: .blocked, count: 1),
             .init(disposition: .waitingOnYou, count: 1)]
        case .halted, .starved:
            [.init(disposition: .todo, count: 5)]
        }
        let defaultVerdict = switch state {
        case .running: "running — 2 of 7 Cards done"
        case .done: "advanced — 6 Cards done, 2 need you"
        case .halted: "halted — Acts failed; see Health"
        case .starved: "starved — no Card was dispatched"
        }
        return NightPulse(
            state: state,
            startedAt: time(1, 30),
            verdictLine: verdict ?? defaultVerdict,
            cardsByDisposition: dispositions ?? defaultDispositions,
            nightCard: issueLink("YH-100")
        )
    }

    // MARK: Pools

    static let cardTitles = [
        "Refuse a second Journal open from the app",
        "Show the next scheduled Act in yh status",
        "Revalidate the Lease before the Outbox flush",
        "Name the Repo in the Partial Landing announcement",
        "Carry banked replies into the adopting dispatch",
        "Stop the land Act when the predecessor is unmerged",
        "Explain an empty Routing Table in yh doctor",
        "Keep the Night Card verdict line under one line"
    ]

    static let blockReasonCycle: [BlockReason] = [
        .reviewerRejection, .checkFailure, .routeFailure, .reviewerRejection, .hostCrash,
        .replyOverdue, .decisionOverdue
    ]

    static let attemptStatuses = [
        "Round 1 — worker writing changes",
        "Round 2 — reviewer asked for changes",
        "running the Check",
        "Round 1 — reviewer reading the diff"
    ]

    static let routes = ["claude/opus-5-5/high", "codex/gpt-5.6-sol/medium", "claude/sonnet-5/medium"]
}

// MARK: - Knobs

/// Edits the playground's controls make. Each keeps the Pulse self-consistent, so a variant never
/// has to cope with a state the engine cannot produce (e.g. running Attempts on an `idle` Project).
extension PulseSnapshot {
    mutating func setWaitingOnYou(_ count: Int) {
        let blocked = needsYou.cards.filter { $0.state == .blocked }
        let waiting = (0..<count).map { index in
            DecisionCard(
                id: "YH-\(140 + index)",
                title: PulseFixtures.cardTitles[index % PulseFixtures.cardTitles.count],
                state: .waitingOnYou,
                blockReason: nil,
                repo: PulseFixtures.defaultRepos[index % PulseFixtures.defaultRepos.count],
                link: PulseFixtures.issueLink("YH-\(140 + index)")
            )
        }
        needsYou.cards = waiting + blocked
    }

    mutating func setBlocked(_ count: Int) {
        let waiting = needsYou.cards.filter { $0.state == .waitingOnYou }
        let blocked = (0..<count).map { index in
            DecisionCard(
                id: "YH-\(160 + index)",
                title: PulseFixtures.cardTitles.reversed()[index % PulseFixtures.cardTitles.count],
                state: .blocked,
                blockReason: PulseFixtures.blockReasonCycle[index % PulseFixtures.blockReasonCycle.count],
                repo: PulseFixtures.defaultRepos[(index + 1) % PulseFixtures.defaultRepos.count],
                // The third has no recorded link yet, to show a way out that is absent.
                link: index == 2 ? nil : PulseFixtures.issueLink("YH-\(160 + index)")
            )
        }
        needsYou.cards = waiting + blocked
    }

    /// Running Attempts spread round-robin across `repos`. Any Attempt makes the Project `working`.
    mutating func setAttempts(_ count: Int, across repos: [String]) {
        guard !repos.isEmpty else { return }
        now.attempts = (0..<count).map { index in
            RunningAttempt(
                id: "attempt-\(index + 1)",
                cardID: "YH-\(130 + index)",
                cardTitle: PulseFixtures.cardTitles[(index + 2) % PulseFixtures.cardTitles.count],
                repo: repos[index % repos.count],
                route: PulseFixtures.routes[index % PulseFixtures.routes.count],
                startedAt: PulseFixtures.minutesBeforeAsOf(12 + index * 17),
                round: index % 2 + 1,
                status: PulseFixtures.attemptStatuses[index % PulseFixtures.attemptStatuses.count],
                cardLink: PulseFixtures.issueLink("YH-\(130 + index)")
            )
        }
        if count > 0 { now.status = .working }
    }

    /// `idle` means the Act job is not alive, so it clears running Attempts too.
    mutating func setStatus(_ status: ProjectStatus) {
        now.status = status
        if status == .idle { now.attempts = [] }
    }

    /// Raises or clears one flag, keeping the flags in `HealthFlagKind` order.
    mutating func setHealthFlag(_ kind: HealthFlagKind, _ raised: Bool) {
        var kinds = Set((health ?? []).map(\.kind))
        if raised { kinds.insert(kind) } else { kinds.remove(kind) }
        health = HealthFlagKind.allCases.filter(kinds.contains).map { kind in
            let detail = switch kind {
            case .staleOperatorIdentity: "The Operator identity was last confirmed 41 days ago."
            case .appInstallationRevoked: "The Linear workspace revoked the App Installation."
            case .probeFailure: "codex failed its Probe: exit status 127."
            case .actFailure: "build · main: Worktree allocation failed."
            }
            return HealthFlag(kind: kind, detail: detail)
        }
    }

    mutating func setAllHealthFlags(_ raised: Bool) {
        for kind in HealthFlagKind.allCases { setHealthFlag(kind, raised) }
    }
}
#endif
