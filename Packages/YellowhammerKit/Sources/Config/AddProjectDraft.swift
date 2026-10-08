import Domain
import Foundation

/// The Add Project wizard's state as plain values. Nothing here runs `yh` or touches the disk: the
/// ``context`` carries what the wizard knows about the Mac, and ``setupInvocation`` is what it asks `yh` to do.
public struct AddProjectDraft: Equatable, Sendable {
    /// The wizard's seven steps, in the order the hub lists them.
    public enum Step: Int, CaseIterable, Identifiable, Comparable, Sendable {
        case project
        case board
        case repos
        case github
        case specSource
        case bounds
        case jobs

        public var id: Self { self }

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

        public var number: Int { rawValue + 1 }

        public var title: String {
            switch self {
            case .project: "Project"
            case .board: "Board"
            case .repos: "Repos"
            case .github: "GitHub"
            case .specSource: "Spec Source"
            case .bounds: "Bounds"
            case .jobs: "Scheduled jobs" // glossary:ignore GL001
            }
        }

        public var shortTitle: String {
            switch self {
            case .project: "Project"
            case .board: "Board"
            case .repos: "Repos"
            case .github: "GitHub"
            case .specSource: "Spec Source"
            case .bounds: "Bounds"
            case .jobs: "Schedule"
            }
        }

        /// One sentence on what the step decides.
        public var explanation: String {
            switch self {
            case .project:
                "Name the Project. Its id names the Project file, its Journal and its LaunchAgents."
            case .board:
                "Where this Project\u{2019}s Features are planned: the Linear workspace, then the "
                    + "Linear project they come from, or a team to create one in." // glossary:ignore GL001
            case .repos:
                "The working Repos this Project builds in. A working Repo belongs to exactly one Project."
            case .github:
                "The GitHub token Yellowhammer pushes Feature Branches and opens pull requests with. "
                    + "It is checked against every working Repo."
            case .specSource:
                "Yellowhammer cites one specification when it authors a Feature. It reads it and never writes to it."
            case .bounds:
                "Limits that keep a Night from grinding. Past one, work stops or is raised to you."
            case .jobs:
                "When the Night runs. launchd runs every Act; the app never schedules." // glossary:ignore GL001
            }
        }

        /// Bounds and the Schedule: their defaults work, but the Operator still passes through them once, so a
        /// Project is never added on limits and a Night window nobody looked at.
        public var hasWorkingDefaults: Bool { self == .bounds || self == .jobs }

        /// The step after this one in the hub's order, or nil for the last.
        public var next: Self? { Self(rawValue: rawValue + 1) }

        public var systemImage: String {
            switch self {
            case .project: "square.stack.3d.up"
            case .board: "link"
            case .repos: "folder"
            case .github: "key"
            case .specSource: "doc.text"
            case .bounds: "gauge.with.dots.needle.33percent"
            case .jobs: "moon.stars"
            }
        }
    }

    /// Where a step stands in the hub.
    public enum StepStatus: Sendable {
        case done
        case problem
        case current
        case upcoming
    }

    public enum LinearProjectChoice: Hashable, Sendable { // glossary:ignore GL001
        case existing
        case createInTeam
    }

    /// What a check of the Linear project id against the selected workspace found.
    public enum LinearVerification: Equatable, Sendable {
        case unchecked
        case checking
        case verified(name: String, teamNames: [String])
        case notFound
        case noTeamAccess(teamNames: [String])

        public var isVerified: Bool {
            if case .verified = self { return true }
            return false
        }

        public var isUnchecked: Bool {
            if case .unchecked = self { return true }
            return false
        }
    }

    public enum SpecSourceChoice: Hashable, Sendable {
        /// A read-only path, shareable across Projects; no Repo Role, Check or Protected Paths.
        case path
        /// One of this Project's Repos, with role "spec".
        case repo
    }

    public enum JobsChoice: Hashable, Sendable {
        case install
        case export
        case notNow
    }

    /// A Repo as the wizard edits it. Not Config's `RepoDeclaration`: every field is still free text.
    public struct Repo: Identifiable, Equatable, Sendable {
        public var id = UUID()
        public var path: String
        public var name: String
        public var role: String
        /// Never defaulted: `none` is declared, so silence never means "no gate".
        public var check: String

        public init(path: String, name: String? = nil, role: String = "", check: String = "") {
            self.path = path
            self.name = name ?? URL(filePath: path).lastPathComponent
            self.role = role
            self.check = check
        }

        /// The path with the home directory written as `~`.
        public var displayPath: String { (path as NSString).abbreviatingWithTildeInPath }
    }

    /// "A, B, and C": pinned to English so the copy does not change with the Mac's region.
    static let listStyle = ListFormatStyle<StringStyle, [String]>
        .list(type: .and).locale(Locale(identifier: "en_US"))

    public var step: Step = .project
    /// The steps the Operator has opened, so a hub shows a step's problems only once it was visited.
    public var visited: Set<Step> = [.project]
    /// The steps the Operator has moved on from. A step's problems show only once it was left, so nothing is
    /// reported as wrong on the first opening of a page.
    public var left: Set<Step> = []

    // Project
    public var projectID = ""
    public var name = ""
    /// Whether the Operator typed the id; until then it follows the name.
    public var idEdited = false
    /// Whether the Operator confirmed the id.
    public var idConfirmed = false

    // Linear project
    /// The local name of the Linear Board Connection the Operator selected; nil is not chosen.
    public var linearInstallationName: String?
    public var linearChoice: LinearProjectChoice = .existing
    /// A typed or picked Linear project id; trimmed empty means not chosen.
    public var linearProjectID = "" {
        didSet {
            guard linearProjectID != oldValue else { return }
            if let project = context.linearProjects.first(where: { $0.id == linearProjectID }) {
                linearVerification = .verified(name: project.name, teamNames: project.teamNames)
            } else {
                linearVerification = .unchecked
            }
        }
    }
    public var linearVerification: LinearVerification = .unchecked
    public var teamKey: String?

    // Repos
    public var repos: [Repo] = []

    // GitHub
    /// What `yh setup --print-github` last reported for ``workingRepoPaths``; nil until a check ran.
    public var gitHubReport: GitHubCredentialReport?
    /// The working Repo paths (as the draft had them) that `gitHubReport` was checked against.
    public var gitHubCheckedRepoPaths: [String] = []

    // Spec Source
    public var specChoice: SpecSourceChoice = .path
    public var specSourcePath = ""

    // Bounds
    public var bounds = Bounds()

    // Scheduled jobs
    /// The Project's `[schedule]`: the Night window and the build interval its LaunchAgents are generated from.
    public var schedule = Schedule()
    public var jobs: JobsChoice = .install
    public var exportDirectory = ""
    public var exportUsesCron = false

    public var context = AddProjectContext()

    public init() {}
}
