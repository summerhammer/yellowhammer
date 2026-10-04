#if DEBUG
import Foundation

// MARK: - Summaries

extension AddProjectDraft {
    var linearProject: LinearProjectFixture? { // glossary:ignore GL001
        AddProjectFixtures.allLinearProjects.first { $0.id == linearProjectID }
    }

    var team: TeamFixture? { (AddProjectFixtures.teams + AddProjectFixtures.otherTeams).first { $0.key == teamKey } }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? projectID : trimmed
    }

    /// A one-line account of what a step decided, for the hub's step list.
    func summary(of step: WizardStep) -> String {
        switch step {
        case .project: projectSummary
        case .repos: repos.isEmpty ? "No Repos yet" : repos.map(\.name).formatted(.list(type: .and))
        case .specSource: specSourceSummary
        case .bounds: boundsSummary
        case .jobs: jobsSummary
        }
    }

    private var projectSummary: String {
        guard !projectID.isEmpty else { return "Not named yet" }
        return "\(displayName) · \(linearSummary)"
    }

    /// "Acme · acme", for the step that holds the name and id.
    var identitySummary: String {
        projectID.isEmpty ? "Not named yet" : "\(displayName) · \(projectID)"
    }

    /// The Linear project chosen, or what is missing.
    var linearSummary: String {
        switch linearChoice {
        case .existing:
            linearProject.map { "\u{201c}\($0.name)\u{201d}" } ?? "no Linear project" // glossary:ignore GL001
        case .createInTeam:
            team.map { "new in \($0.name)" } ?? "no team"
        }
    }

    private var specSourceSummary: String {
        switch specChoice {
        case .path:
            specSourcePath.isEmpty
                ? "Not chosen"
                : specSourcePath.replacingOccurrences(of: AddProjectFixtures.home, with: "~")
        case .repo:
            repos.first { $0.role == "spec" }.map { "Repo \($0.name)" } ?? "No spec Repo"
        }
    }

    private var boundsSummary: String {
        bounds.isDefault
            ? "Defaults"
            : "\(bounds.reviewRoundsMax) Rounds · \(bounds.attemptsPerCard) Attempts · "
                + "\(bounds.unansweredNightsMax) Nights"
    }

    private var jobsSummary: String {
        let window = "\(nightStart)–\(nightEnd), build every \(buildEveryMinutes) min"
        return switch jobs {
        case .install: "LaunchAgents · \(window)"
        case .export: "Export \(exportUsesCron ? "cron" : "launchd") · \(window)"
        case .notNow: "Not installed"
        }
    }

    /// The fixture run's output, played back by the last screen.
    var runLog: [String] {
        let head = [
            "$ yh setup --init --project \(projectID)",
            "Wrote ~/.config/yellowhammer/projects/\(projectID).toml",
            "Checked \(repos.count) Repo\(repos.count == 1 ? "" : "s") with git 2.47"
        ]
        if runFails {
            return head + ["error: launchctl bootstrap gui/501 refused dev.yellowhammer.\(projectID).build"]
        }
        let jobs = switch self.jobs {
        case .install: "Installed dev.yellowhammer.\(projectID).{author,build,land}"
        case .export: "Exported the scheduled jobs to \(exportDirectory)" // glossary:ignore GL001
        case .notNow: "Skipped the scheduled jobs" // glossary:ignore GL001
        }
        return head + [jobs, "Project \u{201c}\(displayName)\u{201d} added."]
    }
}
#endif
