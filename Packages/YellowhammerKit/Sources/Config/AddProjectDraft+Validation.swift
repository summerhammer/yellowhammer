import Domain
import Foundation

// MARK: - Validation

extension AddProjectDraft {
    /// Human sentences, empty when the step is complete.
    public func problems(in step: Step) -> [String] {
        switch step {
        case .project: projectProblems
        case .board: linearProblems
        case .repos: repoProblems
        case .github: gitHubProblems
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

    /// What the Linear project id's verification stands at: if the id is in the workspace's listed projects,
    /// it counts as verified without needing a separate verify run.
    public var effectiveLinearVerification: LinearVerification {
        let trimmed = linearProjectID.trimmingCharacters(in: .whitespacesAndNewlines)
        if let project = context.linearProjects.first(where: { $0.id == trimmed && !trimmed.isEmpty }) {
            return .verified(name: project.name, teamNames: project.teamNames)
        }
        return linearVerification
    }

    /// Whether the chosen Linear project id has been verified against the workspace.
    public var isLinearProjectVerified: Bool {
        effectiveLinearVerification.isVerified
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
        case .existing:
            let trimmed = linearProjectID.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return ["Choose the Linear project, or create one in a team."] // glossary:ignore GL001
            }
            let workspace = selectedLinearInstallation?.name ?? "this workspace"
            switch effectiveLinearVerification {
            case .verified:
                return []
            case .unchecked, .checking:
                return ["Verify the Linear project id."] // glossary:ignore GL001
            case .notFound:
                return ["No Linear project has that id in \(workspace)."] // glossary:ignore GL001
            case .noTeamAccess(let teamNames):
                let teams: String
                if teamNames.isEmpty {
                    teams = "the team"
                } else if teamNames.count == 1 {
                    teams = "the team \(teamNames[0])"
                } else {
                    teams = "the teams \(teamNames.formatted(Self.listStyle))"
                }
                return ["Yellowhammer is not a member of \(teams)."]
            }
        case .createInTeam where teamKey == nil:
            return ["Choose a team to create the Linear project in."] // glossary:ignore GL001
        case .createInTeam:
            return []
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

    /// The Repos a GitHub token must be able to publish: every Repo whose role is not `spec` (the Spec Source is
    /// read-only), as the Operator entered their paths.
    public var workingRepoPaths: [String] {
        repos.filter { $0.role != "spec" }.map(\.path)
    }

    /// Whether the last GitHub check was made against the working Repos the draft has now.
    public var gitHubCheckIsCurrent: Bool {
        guard gitHubReport != nil else { return false }
        func normalized(_ paths: [String]) -> [String] { paths.map(AddProjectContext.normalizedPath).sorted() }
        return normalized(gitHubCheckedRepoPaths) == normalized(workingRepoPaths)
    }

    private var gitHubProblems: [String] {
        // Only Repos of role `spec` leave nothing to push to, but the token is still the Project's: its check
        // is then of the credential alone. No Repos at all is the Repos step's problem to name first.
        guard !repos.isEmpty else { return ["Add a working Repo first."] }
        guard let report = gitHubReport, gitHubCheckIsCurrent else { return ["Check the GitHub token."] }
        guard report.state == .resolves else { return [report.message] }
        return report.repos.filter { $0.status != .ok && $0.status != .okUnverified }.map(\.message)
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
