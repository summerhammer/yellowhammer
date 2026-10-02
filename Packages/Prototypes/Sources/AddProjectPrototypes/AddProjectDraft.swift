#if DEBUG
import Foundation

// The Add Project wizard's state as plain values, so every variant renders the same draft and the
// Playground can swap scenarios. Nothing here runs `yh` or touches the disk: "Choose…" picks the next
// fixture folder and "Add Project" plays back a fixture run.

/// The wizard's five steps, in the order the wireframe gives them.
enum WizardStep: Int, CaseIterable, Identifiable, Comparable {
    case project
    case repos
    case specSource
    case bounds
    case jobs

    var id: Self { self }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var number: Int { rawValue + 1 }

    var title: String {
        switch self {
        case .project: "Project & Linear project" // glossary:ignore GL001
        case .repos: "Repos"
        case .specSource: "Spec Source"
        case .bounds: "Bounds"
        case .jobs: "Scheduled jobs" // glossary:ignore GL001
        }
    }

    var shortTitle: String {
        switch self {
        case .project: "Project"
        case .repos: "Repos"
        case .specSource: "Spec Source"
        case .bounds: "Bounds"
        case .jobs: "Schedule"
        }
    }

    /// The wireframe's qualifier, shown where a variant has room for it.
    var qualifier: String? {
        self == .repos ? "working, exclusive" : nil
    }

    /// One sentence on what the step decides, for variants that lead with an explanation.
    var explanation: String {
        switch self {
        case .project:
            "Name the Project and link the Linear project its Features come from." // glossary:ignore GL001
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

    var systemImage: String {
        switch self {
        case .project: "square.stack.3d.up"
        case .repos: "folder"
        case .specSource: "doc.text"
        case .bounds: "gauge.with.dots.needle.33percent"
        case .jobs: "moon.stars"
        }
    }
}

enum WizardStepStatus {
    case done
    case problem
    case current
    case upcoming
}

enum LinearProjectChoice: Hashable { // glossary:ignore GL001
    case existing
    case createInTeam
}

enum SpecSourceChoice: Hashable {
    /// A read-only path, shareable across Projects; no Repo Role, Check or Protected Paths.
    case path
    /// One of this Project's Repos, with role "spec".
    case repo
}

enum JobsChoice: Hashable {
    case install
    case export
    case notNow
}

enum WizardRun: Equatable {
    case notStarted
    case running
    case succeeded
    case failed
}

struct RepoDraft: Identifiable, Equatable {
    var id = UUID()
    var path: String
    var name: String
    var role: String
    /// Never defaulted: `none` is declared, so silence never means "no gate".
    var check: String

    init(path: String, name: String? = nil, role: String = "", check: String = "") {
        self.path = path
        self.name = name ?? URL(filePath: path).lastPathComponent
        self.role = role
        self.check = check
    }

    var displayPath: String {
        path.replacingOccurrences(of: AddProjectFixtures.home, with: "~")
    }
}

struct AddProjectDraft: Equatable {
    var step: WizardStep = .project
    /// The furthest step reached, so a variant can let the Operator jump back but not ahead.
    var reached: WizardStep = .project

    /// The steps the Operator has opened, so a hub shows a step's problems only once it was visited.
    var visited: Set<WizardStep> = [.project]

    // Project & Linear project
    var projectID = ""
    var name = ""
    /// Whether the Operator typed the id; until then it follows the name.
    var idEdited = false
    /// Whether the Operator confirmed the id, for variants that ask before moving on.
    var idConfirmed = false
    var linearChoice: LinearProjectChoice = .existing
    var linearProjectID: String?
    var teamKey: String?

    // Repos
    var repos: [RepoDraft] = []

    // Spec Source
    var specChoice: SpecSourceChoice = .path
    var specSourcePath = ""

    // Bounds
    var bounds = BoundsDraft()

    // Scheduled jobs
    var jobs: JobsChoice = .install
    var exportDirectory = ""
    var exportUsesCron = false
    var nightStart = "22:00"
    var nightEnd = "06:00"
    var buildEveryMinutes = 15

    // Run
    var run: WizardRun = .notStarted
    /// The Playground's switch for which fixture run plays back.
    var runFails = false
}

// MARK: - Validation

extension AddProjectDraft {
    /// Human sentences, empty when the step is complete.
    func problems(in step: WizardStep) -> [String] {
        switch step {
        case .project: projectProblems
        case .repos: repoProblems
        case .specSource: specSourceProblems
        case .bounds: boundsProblems
        case .jobs: jobsProblems
        }
    }

    func isComplete(_ step: WizardStep) -> Bool { problems(in: step).isEmpty }

    var isComplete: Bool { WizardStep.allCases.allSatisfy(isComplete) }

    /// Where a step stands for a step list: problems show only once the step has been reached, so a
    /// fresh wizard is not a wall of red.
    func status(of step: WizardStep) -> WizardStepStatus {
        if step == self.step { return .current }
        if step > reached { return .upcoming }
        return isComplete(step) ? .done : .problem
    }

    /// Where a step stands in a hub, where any step can be opened: done when complete, a problem once
    /// visited and still incomplete, untouched otherwise.
    func hubStatus(of step: WizardStep) -> WizardStepStatus {
        if isComplete(step) { return .done }
        return visited.contains(step) ? .problem : .upcoming
    }

    var incompleteSteps: [WizardStep] { WizardStep.allCases.filter { !isComplete($0) } }

    /// "Still needed: Spec Source and Schedule", or nil when every step is complete.
    var stillNeeded: String? {
        guard !incompleteSteps.isEmpty else { return nil }
        return "Still needed: " + incompleteSteps.map(\.shortTitle).formatted(.list(type: .and))
    }

    /// Set when a removed Project left a Journal under this id: the new Project continues its history.
    var reusesJournal: Bool { AddProjectFixtures.existingJournalIDs.contains(projectID) }

    /// Why a Repo cannot be declared here, if it cannot.
    func conflict(for repo: RepoDraft) -> String? {
        if let owner = AddProjectFixtures.workingRepos[repo.path] {
            return "already a working Repo in \(owner)"
        }
        if repos.count(where: { $0.path == repo.path }) > 1 {
            return "declared twice"
        }
        if repo.path == specSourcePath, specChoice == .path {
            return "already the Spec Source"
        }
        return nil
    }

    /// A Repo row's missing fields, if any.
    func missingFields(of repo: RepoDraft) -> [String] {
        [("name", repo.name), ("role", repo.role), ("Check", repo.check)]
            .filter { $0.1.trimmingCharacters(in: .whitespaces).isEmpty }
            .map(\.0)
    }

    private var projectProblems: [String] { identityProblems + linearProblems }

    /// The name-and-id half of the first step, for variants that split it in two.
    var identityProblems: [String] {
        var problems: [String] = []
        let id = projectID.trimmingCharacters(in: .whitespaces)
        if id.isEmpty {
            problems.append("Enter a Project id.")
        } else if id.contains(where: { !($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) {
            problems.append("A Project id is letters, digits, underscores and hyphens.")
        } else if AddProjectFixtures.existingProjectIDs.contains(id) {
            problems.append("A Project \u{201c}\(id)\u{201d} already exists.")
        }
        return problems
    }

    /// The Linear half of the first step, for variants that split it in two.
    var linearProblems: [String] {
        var problems: [String] = []
        switch linearChoice {
        case .existing where linearProjectID == nil:
            problems.append("Choose the Linear project, or create one in a team.") // glossary:ignore GL001
        case .createInTeam where teamKey == nil:
            problems.append("Choose a team to create the Linear project in.") // glossary:ignore GL001
        default:
            break
        }
        return problems
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
                problems.append("\(repo.displayPath) needs a \(missing.formatted(.list(type: .and))).")
            }
        }
        return problems
    }

    private var specSourceProblems: [String] {
        let specRepos = repos.filter { $0.role == "spec" }
        switch specChoice {
        case .path:
            if specSourcePath.isEmpty { return ["Choose the Spec Source folder."] }
            if !specRepos.isEmpty {
                return ["\(specRepos[0].name) has role \u{201c}spec\u{201d} too; a Project has exactly one."]
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
        BoundsDraft.all
            .filter { bounds[keyPath: $0.keyPath] < 1 }
            .map { "\($0.title) must be at least 1." }
    }

    private var jobsProblems: [String] {
        var problems: [String] = []
        if nightStart == nightEnd {
            problems.append("The Night cannot start and end at the same time.")
        }
        if jobs == .export, exportDirectory.isEmpty {
            problems.append("Choose the folder to export the scheduled jobs to.") // glossary:ignore GL001
        }
        return problems
    }
}
#endif
