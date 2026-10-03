import Config
import Domain
import Engine
import Foundation
import Journal
import Repositories

/// `yh project remove <id>`'s orchestration (roadmap P13.5; spec risks.md OQ52(1)), with every side
/// effect injected as a seam, mirroring ``Doctor``/``Status``.
///
/// Removal is not an Act: it claims no Act Lease of its own (`recordProjectRemoval` refuses instead
/// while any Act of this Project holds one). It never deletes the Journal or anything on Linear — only
/// the machine-local footprint: the three LaunchAgents, the three Act logs, held Worktrees (after a
/// WIP-commit-and-push of any uncommitted edits), and finally `projects/<id>.toml`.
struct ProjectRemoval {
    let configurationDirectory: URL
    let homeDirectory: URL
    let output: (String) -> Void
    let console: any SetupConsole
    let launchAgents: any LaunchAgentControl
    /// Builds the board-writing seam once the Project is resolved (mirrors ``Doctor``'s
    /// `bindProvisioning`): a Project with no in-flight Feature never calls this, so it never touches
    /// the Keychain.
    let bindBoard: (Configuration, ProjectConfiguration) throws -> any BoardWriting
    let workspace: any Workspace
    let git: GitRunner
    /// Builds the push seam once the Project is resolved; the returned closure resolves the GitHub
    /// token lazily, on each call (as ``LandBinding/push(configuration:project:credentials:)`` does), so
    /// a removal with nothing to push never touches the Keychain either.
    let bindPush: (Configuration, ProjectConfiguration)
        -> @Sendable (FeatureBranch, Repo, NightMode) async -> PushOutcome
    let now: Date

    /// Names each replacement the lenient load made for the safety WIP Commit: a refused
    /// `wip_commit_message` falls back to the built-in default, an empty or non-string `change_type` to
    /// `feat`. Neither blocks the WIP Commit (OQ103 (f)).
    private func reportWIPCommitFallbacks(project: ProjectConfiguration) {
        for refusal in project.unvalidatedTemplates?.refusals ?? [] {
            switch refusal.key {
            case "git.wip_commit_message":
                output("\(refusal)")
                output("using the built-in WIP Commit message instead")
            case "change_type":
                output("\(refusal)")
                output("using change_type \"feat\" instead")
            default:
                break
            }
        }
    }

    /// Runs the whole removal for `id`, printing progress and a final summary line. Returns whether it
    /// succeeded, the command's exit code.
    func run(id: String, yes: Bool) async -> Bool {
        let configuration: Configuration
        let project: ProjectConfiguration
        do {
            (configuration, project) = try ProjectResolution.resolve(
                projectArgument: id, configurationDirectory: configurationDirectory, lenientTemplates: true
            )
        } catch {
            output("\(error)")
            return false
        }

        reportWIPCommitFallbacks(project: project)

        let journal = openJournalIfPresent(projectID: project.id)
        if let journal {
            if let refusal = refusalIfActLeaseHeld(journal: journal) {
                output(refusal)
                return false
            }
        }

        guard yes || confirmRemoval(id: project.id.rawValue) else {
            output("nothing removed")
            return false
        }

        var failures: [String] = []
        await removeLaunchAgents(projectID: project.id, failures: &failures)
        await removeLogs(projectID: project.id)

        if let journal {
            guard await removeJournaledFootprint(
                journal: journal, configuration: configuration, project: project, failures: &failures
            ) else {
                return false
            }
        }

        guard failures.isEmpty else {
            report(failures: failures)
            return false
        }

        deleteProjectFile(id: project.id)
        output("Project \(project.id.rawValue) removed. Its Journal was kept.") // glossary:ignore GL001
        return true
    }

    /// Steps 7-10, run only when the Project has a Journal: comments on the in-flight Feature, WIP-
    /// commits/pushes/removes its held Worktrees, then writes the removal to the Journal. Returns
    /// whether this succeeded — false means `run` should stop and report without touching the TOML.
    private func removeJournaledFootprint(
        journal: JournalStore, configuration: Configuration, project: ProjectConfiguration,
        failures: inout [String]
    ) async -> Bool {
        let boardWriting: () throws -> any BoardWriting = { try bindBoard(configuration, project) }
        let push = bindPush(configuration, project)

        let mode = resolveMode(journal: journal)
        var featureIssueID: String?
        if let (feature, _) = try? journal.inFlightFeature() {
            featureIssueID = feature.issueID
            let clientID = OutboxClientID.make(
                projectID: project.id, salt: journal.outboxSalt, key: "project-removed:\(feature.issueID)"
            )
            let body = ProjectRemovalComment(projectID: project.id, mode: mode).body()
            if configuration.machine.linearInstallation(for: project) == nil {
                // fire-an-act-on-schedule; OQ109 item 10: with the Project's App Installation gone from
                // config.toml there is no identity to comment as, and a missing installation never blocks
                // removal: it proceeds, reports the skip, and counts it as a succeeded step. An
                // installation that is present but refused by Linear is not this case (OQ119): that
                // comment step still fails below.
                output(
                    "skipped the release comment on \(feature.issueID): Linear App Installation "
                        + "\"\(project.linearInstallationName)\" is not in config.toml"
                )
            } else {
                await postRemovalComment(
                    feature: feature, clientID: clientID, body: body, bindBoard: boardWriting, failures: &failures
                )
            }
        }

        let worktreeResult = await removeWorktrees(journal: journal, project: project, mode: mode, push: push)
        let releasedWorktreeIDs = worktreeResult.releasedWorktreeIDs
        failures.append(contentsOf: worktreeResult.failures)

        guard failures.isEmpty else {
            report(failures: failures)
            return false
        }

        do {
            _ = try journal.recordProjectRemoval(
                NewProjectRemoval(featureIssueID: featureIssueID, releasedWorktreeIDs: releasedWorktreeIDs),
                runID: RunID(), now: now
            )
            return true
        } catch {
            output("refused: \(error)")
            return false
        }
    }

    // MARK: - Steps 1-4

    /// Never creates a Journal: opens it only when `journals/<id>.db` already exists.
    private func openJournalIfPresent(projectID: ProjectID) -> JournalStore? {
        let fileURL = JournalStore.defaultFileURL(configurationDirectory: configurationDirectory, id: projectID)
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else { return nil }
        return try? JournalStore.openExisting(configurationDirectory: configurationDirectory, projectID: projectID)
    }

    private func refusalIfActLeaseHeld(journal: JournalStore) -> String? {
        guard let lease = try? journal.currentActLease(), lease.isHeld(at: now) else { return nil }
        return "refused: \(lease.act.rawValue) run \(lease.runID.rawValue) holds \(journal.projectID.rawValue)'s "
            + "Act lease until \(lease.expiresAt)"
    }

    private func confirmRemoval(id: String) -> Bool {
        output("This will, for Project \(id):") // glossary:ignore GL001
        output("- unload and delete its 3 LaunchAgents")
        output("- delete its 3 Act logs")
        output("- comment on its in-flight Feature Issue, if one exists")
        output("- WIP-commit, push and remove each of its held Worktrees")
        output("- close its open Night, if one exists")
        output("- keep its Journal")
        output("- delete projects/\(id).toml") // glossary:ignore GL001
        guard let answer = console.ask("Remove Project \(id)? [y/N] ") else { return false }
        let normalized = answer.trimmingCharacters(in: .whitespaces).lowercased()
        return normalized == "y" || normalized == "yes"
    }

    private func report(failures: [String]) {
        for failure in failures {
            output(failure)
        }
        output("removal incomplete; re-run `yh project remove <id>` to retry") // glossary:ignore GL001
    }

    private func deleteProjectFile(id: ProjectID) {
        let projectFile = configurationDirectory.appending(
            components: "projects", "\(id.rawValue).toml", directoryHint: .notDirectory
        )
        try? FileManager.default.removeItem(at: projectFile)
    }
}
