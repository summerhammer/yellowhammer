#if DEBUG
import Foundation

// MARK: - Summaries

extension AddProjectDraft {
    var linearProject: LinearProjectFixture? { // glossary:ignore GL001
        AddProjectFixtures.linearProjects.first { $0.id == linearProjectID }
    }

    var team: TeamFixture? { AddProjectFixtures.teams.first { $0.key == teamKey } }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? projectID : trimmed
    }

    /// A one-line account of what a step decided, for collapsed and checklist variants.
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

    /// "Acme · acme", for variants that give the name and id their own step.
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

    /// The Project file `yh setup --init` would write, for the variants that show it.
    var projectFilePreview: String {
        var lines = [
            "# ~/.config/yellowhammer/projects/\(projectID.isEmpty ? "<id>" : projectID).toml",
            "id = \"\(projectID)\"",
            "name = \"\(displayName)\""
        ]
        switch linearChoice {
        case .existing: lines.append("linear_project = \"\(linearProjectID ?? "")\"")
        case .createInTeam: lines.append("linear_project = \"<new in \(teamKey ?? "?")>\"")
        }
        if specChoice == .path, !specSourcePath.isEmpty {
            lines.append("spec_source = \"\(specSourcePath)\"")
        }
        for repo in repos {
            lines += [
                "",
                "[[repos]]",
                "name = \"\(repo.name)\"",
                "path = \"\(repo.path)\"",
                "role = \"\(repo.role)\"",
                "check = \"\(repo.check)\""
            ]
        }
        let changedBounds = BoundsDraft.all.filter {
            bounds[keyPath: $0.keyPath] != BoundsDraft()[keyPath: $0.keyPath]
        }
        if !changedBounds.isEmpty {
            lines += ["", "[limits]"]
            lines += changedBounds.map { "\($0.key) = \(bounds[keyPath: $0.keyPath])" }
        }
        lines += [
            "",
            "[schedule]",
            "night_start = \"\(nightStart)\"",
            "night_end = \"\(nightEnd)\"",
            "build_every_minutes = \(buildEveryMinutes)"
        ]
        return lines.joined(separator: "\n")
    }

    /// The fixture run's output, played back by every variant's last screen.
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
