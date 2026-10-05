import Foundation

// MARK: - Summaries

extension AddProjectDraft {
    /// The name, or the id while there is no name.
    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? projectID : trimmed
    }

    /// A one-line account of what a step decided. Each starts with a capital: it opens a sidebar row.
    public func summary(of step: Step) -> String {
        switch step {
        case .project: identitySummary
        case .board: linearSummary
        case .repos: repos.isEmpty ? "No Repos yet" : repos.map(\.name).formatted(Self.listStyle)
        case .specSource: specSourceSummary
        case .bounds: boundsSummary
        case .jobs: jobsSummary
        }
    }

    /// "Acme · acme".
    public var identitySummary: String {
        projectID.isEmpty ? "Not named yet" : "\(displayName) · \(projectID)"
    }

    private var linearSummary: String {
        guard let installation = linearInstallationName else { return "No Linear workspace" }
        return "\(linearProjectSummary) \u{b7} \(installation)"
    }

    private var linearProjectSummary: String {
        switch linearChoice {
        case .existing:
            let id = linearProjectID.trimmingCharacters(in: .whitespacesAndNewlines)
            if id.isEmpty { return "No Linear project" } // glossary:ignore GL001
            let listed = context.linearProjects.first { $0.id == id }
            let verifiedName: String? = {
                if case .verified(let name, _) = effectiveLinearVerification, !name.isEmpty {
                    return name
                }
                return nil
            }()
            return "\u{201c}\(listed?.name ?? verifiedName ?? id)\u{201d}"
        case .createInTeam:
            guard let teamKey else { return "No team" }
            let team = context.teams.first { $0.key == teamKey }
            return "New in \(team?.name ?? teamKey)"
        }
    }

    private var specSourceSummary: String {
        switch specChoice {
        case .path:
            specSourcePath.isEmpty ? "Not chosen" : (specSourcePath as NSString).abbreviatingWithTildeInPath
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
        let window = "\(schedule.nightStart)–\(schedule.nightEnd), build every \(schedule.buildEveryMinutes) min"
        return switch jobs {
        case .install:
            "LaunchAgents · \(window)"
        case .export:
            "Export \(exportUsesCron ? "cron" : "launchd") to "
                + "\((exportDirectory as NSString).abbreviatingWithTildeInPath) · \(window)"
        case .notNow:
            "Not installed"
        }
    }
}
