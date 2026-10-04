import Domain
import Foundation

/// The Add Project wizard's state as plain values. Nothing here runs `yh` or touches the disk: the
/// ``context`` carries what the wizard knows about the Mac, and ``setupInvocation`` is what it asks `yh` to do.
public struct AddProjectDraft: Equatable, Sendable {
    /// The wizard's six steps, in the order the hub lists them.
    public enum Step: Int, CaseIterable, Identifiable, Comparable, Sendable {
        case project
        case board
        case repos
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
    /// The local name of the Linear App Installation the Operator selected; nil is not chosen.
    public var linearInstallationName: String?
    public var linearChoice: LinearProjectChoice = .existing
    /// A typed or picked Linear project id; trimmed empty means not chosen.
    public var linearProjectID = ""
    public var teamKey: String?

    // Repos
    public var repos: [Repo] = []

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

// MARK: - Validation

extension AddProjectDraft {
    /// Human sentences, empty when the step is complete.
    public func problems(in step: Step) -> [String] {
        switch step {
        case .project: projectProblems
        case .board: linearProblems
        case .repos: repoProblems
        case .specSource: specSourceProblems
        case .bounds: boundsProblems
        case .jobs: jobsProblems
        }
    }

    /// A step with working defaults is complete only once the Operator opened it.
    public func isComplete(_ step: Step) -> Bool {
        problems(in: step).isEmpty && (!step.hasWorkingDefaults || visited.contains(step))
    }

    /// Whether the hub reports the step's problems: only once the Operator left it.
    public func revealsProblems(in step: Step) -> Bool { left.contains(step) }

    public var isComplete: Bool { Step.allCases.allSatisfy(isComplete) }

    public var incompleteSteps: [Step] { Step.allCases.filter { !isComplete($0) } }

    /// How many steps are complete.
    public var readyCount: Int { Step.allCases.count { isComplete($0) } }

    /// "Still needed: Board and Spec Source", or nil when every step is complete.
    public var stillNeeded: String? {
        guard !incompleteSteps.isEmpty else { return nil }
        return "Still needed: " + incompleteSteps.map(\.shortTitle).formatted(Self.listStyle)
    }

    /// The registry entry the Operator selected, or nil when none is chosen or the name is not in the registry.
    public var selectedLinearInstallation: LinearInstallation? {
        guard let linearInstallationName else { return nil }
        return context.linearInstallations.first { $0.name == linearInstallationName }
    }

    /// Set when a removed Project left a Journal under this id: the new Project continues its history.
    public var reusesJournal: Bool {
        let id = projectID.trimmingCharacters(in: .whitespaces)
        return context.journalProjectIDs.contains(id) && !context.existingProjectIDs.contains(id)
    }

    /// Why a Repo cannot be declared here, if it cannot.
    public func conflict(for repo: Repo) -> String? {
        let path = AddProjectContext.normalizedPath(repo.path)
        if let owner = context.repoOwners[path] {
            return "already a Repo of \(owner)"
        }
        if repos.count(where: { AddProjectContext.normalizedPath($0.path) == path }) > 1 {
            return "declared twice"
        }
        let spec = specSourcePath.trimmingCharacters(in: .whitespaces)
        if specChoice == .path, !spec.isEmpty, AddProjectContext.normalizedPath(spec) == path {
            return "already the Spec Source"
        }
        return nil
    }

    /// A Repo row's missing fields, if any.
    public func missingFields(of repo: Repo) -> [String] {
        [("name", repo.name), ("role", repo.role), ("Check", repo.check)]
            .filter { $0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map(\.0)
    }

    private var projectProblems: [String] {
        let id = projectID.trimmingCharacters(in: .whitespaces)
        if id.isEmpty { return ["Enter a Project id."] }
        if ProjectID(rawValue: id) == nil {
            return ["A Project id is letters, digits, underscores and hyphens."]
        }
        if context.existingProjectIDs.contains(id) {
            return ["A Project \u{201c}\(id)\u{201d} already exists."]
        }
        return keptJournalProblems(id: id)
    }

    /// Mirrors `yh setup`'s refusal of a kept Journal that cannot be reused.
    private func keptJournalProblems(id: String) -> [String] {
        guard reusesJournal, let kept = context.keptJournals[id] else { return [] }
        let waysOut = "Choose a new Project id, or archive the old Journal (move it out of journals/) first."
        switch kept {
        case .unreadable(let reason):
            return ["The kept Journal for \u{201c}\(id)\u{201d} cannot be read (\(reason)). " + waysOut]
        case .workspace(let workspace):
            guard let installation = selectedLinearInstallation, installation.workspace != workspace else { return [] }
            return [
                "The kept Journal for \u{201c}\(id)\u{201d} was built against another Linear workspace than "
                    + "\u{201c}\(installation.name)\u{201d}. " + waysOut
            ]
        }
    }

    private var linearProblems: [String] {
        if context.linearInstallations.isEmpty { return ["Connect a Linear workspace."] }
        guard let installation = selectedLinearInstallation else {
            return ["Choose the Linear workspace, or connect another."]
        }
        if installation.operatorIdentity == nil {
            return ["Choose your Operator identity in \u{201c}\(installation.name)\u{201d}."]
        }
        return linearProjectProblems
    }

    private var linearProjectProblems: [String] {
        switch linearChoice {
        case .existing where linearProjectID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            ["Choose the Linear project, or create one in a team."] // glossary:ignore GL001
        case .createInTeam where teamKey == nil:
            ["Choose a team to create the Linear project in."] // glossary:ignore GL001
        default:
            []
        }
    }

    private var repoProblems: [String] {
        guard !repos.isEmpty else { return ["Add at least one working Repo."] }
        var problems: [String] = []
        for repo in repos {
            if let conflict = conflict(for: repo) {
                problems.append("\(repo.displayPath) is \(conflict).")
            }
            let missing = missingFields(of: repo)
            if !missing.isEmpty {
                problems.append("\(repo.displayPath) needs a \(missing.formatted(Self.listStyle)).")
            }
        }
        return problems
    }

    private var specSourceProblems: [String] {
        let specRepos = repos.filter { $0.role == "spec" }
        switch specChoice {
        case .path:
            if specSourcePath.trimmingCharacters(in: .whitespaces).isEmpty { return ["Choose the Spec Source folder."] }
            if let first = specRepos.first {
                return ["\(first.name) has role \u{201c}spec\u{201d} too; a Project has exactly one."]
            }
            return []
        case .repo:
            switch specRepos.count {
            case 0: return ["No Repo has role \u{201c}spec\u{201d}."]
            case 1: return []
            default: return ["\(specRepos.count) Repos have role \u{201c}spec\u{201d}; a Project has exactly one."]
            }
        }
    }

    private var boundsProblems: [String] {
        Bounds.fields
            .filter { bounds[keyPath: $0.keyPath] < 1 }
            .map { "\($0.title) must be at least 1." }
    }

    private var jobsProblems: [String] {
        if schedule.nightStart == schedule.nightEnd {
            return ["The Night cannot start and end at the same time."]
        }
        if schedule.buildEveryMinutes < 1 {
            return ["Build every must be at least 1 minute."]
        }
        if jobs == .export, exportDirectory.trimmingCharacters(in: .whitespaces).isEmpty {
            return ["Choose the folder to export the scheduled jobs to."] // glossary:ignore GL001
        }
        return []
    }
}
