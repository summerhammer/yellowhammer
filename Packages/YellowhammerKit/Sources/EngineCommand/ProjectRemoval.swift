import Config
import Domain
import Engine
import Foundation
import Journal
import Repositories

/// `yh project remove <id>`'s orchestration (roadmap P13.5; spec risks.md OQ52(1)), with every side
/// effect injected as a seam, mirroring ``Doctor``/``Status``.
///
/// Removal is not an Act: an isolated SQLite writer transaction excludes overlapping execution
/// and refuses while an Act of this Project holds an unexpired Lease. It never deletes the Journal or anything on Linear — only
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
    let bindDeliveryBoard: ((Configuration, ProjectConfiguration) throws -> ActBoard)?
    let scrub: (@Sendable () -> NarrativeScrub)?
    let deliveryInterrupt: @Sendable (OutboxEntry) throws -> Void
    let workspace: any Workspace
    let git: GitRunner
    /// Builds the push seam once the Project is resolved; the returned closure resolves the GitHub
    /// token lazily, on each call (as ``LandBinding/push(configuration:project:credentials:)`` does), so
    /// a removal with nothing to push never touches the Keychain either.
    let bindPush: (Configuration, ProjectConfiguration)
        -> @Sendable (FeatureBranch, Repo, NightMode) async -> PushOutcome
    let promptStore: any DispatchPromptCleaning
    let now: Date

    init(
        configurationDirectory: URL,
        homeDirectory: URL,
        output: @escaping (String) -> Void,
        console: any SetupConsole,
        launchAgents: any LaunchAgentControl,
        bindBoard: @escaping (Configuration, ProjectConfiguration) throws -> any BoardWriting,
        workspace: any Workspace,
        git: GitRunner,
        bindPush: @escaping (Configuration, ProjectConfiguration)
            -> @Sendable (FeatureBranch, Repo, NightMode) async -> PushOutcome,
        promptStore: (any DispatchPromptCleaning)? = nil,
        now: Date,
        bindDeliveryBoard: ((Configuration, ProjectConfiguration) throws -> ActBoard)? = nil,
        scrub: (@Sendable () -> NarrativeScrub)? = nil,
        deliveryInterrupt: @escaping @Sendable (OutboxEntry) throws -> Void = { _ in }
    ) {
        self.bindDeliveryBoard = bindDeliveryBoard
        self.scrub = scrub
        self.deliveryInterrupt = deliveryInterrupt
        self.configurationDirectory = configurationDirectory
        self.homeDirectory = homeDirectory
        self.output = output
        self.console = console
        self.launchAgents = launchAgents
        self.bindBoard = bindBoard
        self.workspace = workspace
        self.git = git
        self.bindPush = bindPush
        self.promptStore = promptStore ?? DispatchPromptStore(
            rootDirectory: DispatchPromptStore.rootDirectory(configurationDirectory: configurationDirectory)
        )
        self.now = now
    }

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

    /// Deletes the Project's prompt records and the schema copies under its runs directory. A failure
    /// stops removal, reported the same way for both.
    private func removeRecordedPrompts(projectID: ProjectID) -> Bool {
        let failure: String
        do {
            try promptStore.removeAll(projectID: projectID)
            let runsDirectory = CLIAdapterDispatch.runsDirectory(
                configurationDirectory: configurationDirectory, projectID: projectID
            )
            let schemaFailures = SchemaCopySweep.remove(under: runsDirectory)
            if schemaFailures.isEmpty { return true }
            failure = schemaFailures.joined(separator: ", ")
        } catch {
            failure = "\(error)"
        }
        output("could not delete recorded prompts for \(projectID.rawValue): \(failure)")
        output("removal incomplete; re-run `yh project remove <id>` to retry") // glossary:ignore GL001
        return false
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

        let hold: RemovalHold
        do {
            hold = try holdForRemoval(projectID: project.id)
        } catch {
            output("refused: could not exclusively hold the Project for removal: \(error)")
            return false
        }
        defer {
            hold.removal?.rollbackProjectRemoval()
            hold.journalless?.release()
        }
        let journal = hold.removal
        let committedJournal = hold.committed

        guard yes || confirmRemoval(id: project.id.rawValue) else {
            output("nothing removed")
            return false
        }

        var failures: [String] = []
        await removeLaunchAgents(projectID: project.id, failures: &failures)
        await removeLogs(projectID: project.id)

        guard removeRecordedPrompts(projectID: project.id) else { return false }

        if let journal, let committedJournal {
            guard await removeJournaledFootprint(
                journal: journal, committedJournal: committedJournal,
                configuration: configuration, project: project, failures: &failures
            ) else {
                return false
            }
        }

        guard failures.isEmpty else {
            report(failures: failures)
            return false
        }

        guard deleteProjectFile(id: project.id) else { return false }
        output("Project \(project.id.rawValue) removed. Its Journal was kept.") // glossary:ignore GL001
        return true
    }

    /// Steps 5-8, run only when the Project has a Journal: comments on the in-flight Feature, WIP-
    /// commits/pushes/removes its held Worktrees, then writes the removal to the Journal. Returns
    /// whether this succeeded — false means `run` should stop and report without touching the TOML.
    private func removeJournaledFootprint(
        journal: JournalStore, committedJournal: JournalStore,
        configuration: Configuration, project: ProjectConfiguration,
        failures: inout [String]
    ) async -> Bool {
        let boardWriting: () throws -> any BoardWriting = {
            try journal.revalidateProjectRemoval(runID: journal.projectRemovalRunID())
            return try bindBoard(configuration, project)
        }
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
                // fire-an-act-on-schedule; OQ109 item 10: with the Project's Board Connection gone from
                // config.toml there is no identity to comment as, and a missing installation never blocks
                // removal: it proceeds, reports the skip, and counts it as a succeeded step. An
                // installation that is present but refused by Linear is not this case (OQ119): that
                // comment step still fails below.
                output(
                    "skipped the release comment on \(feature.issueID): Linear Board Connection "
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
            let runID = try journal.projectRemovalRunID()
            try await deliverBoardForRemoval(journal: journal, configuration: configuration, project: project)
            let removal = try journal.recordProjectRemoval(
                NewProjectRemoval(featureIssueID: featureIssueID, releasedWorktreeIDs: releasedWorktreeIDs),
                runID: runID, now: now
            )
            try journal.commitProjectRemoval()
            await unpinLandedTips(removal, journal: committedJournal, project: project, runID: runID)
            return true
        } catch {
            output("refused: \(error)")
            return false
        }
    }

    // MARK: - Steps 1-4

    /// Step 1's exclusive hold: the committed Journal, removal's own transaction on it, or — with no
    /// Journal — the hold alone, which keeps an Act from creating one while removal runs.
    /// The exclusive hold is taken before the Journal is opened, and the open runs under it, so removal never
    /// holds a shared hold of its own while it waits for the exclusive one.
    private func holdForRemoval(projectID: ProjectID) throws -> RemovalHold {
        let hold = try JournalStore.holdProjectRemoval(
            configurationDirectory: configurationDirectory, projectID: projectID
        )
        guard let committed = try openJournalIfPresent(projectID: projectID, holding: hold) else {
            return RemovalHold(committed: nil, removal: nil, journalless: hold)
        }
        let removal = try committed.beginProjectRemoval(runID: RunID(), now: now, holding: hold)
        return RemovalHold(committed: committed, removal: removal, journalless: nil)
    }

    /// Never creates a Journal: opens it only when `journals/<id>.db` already exists.
    private func openJournalIfPresent(projectID: ProjectID, holding hold: ProjectRemovalHold) throws -> JournalStore? {
        let fileURL = JournalStore.defaultFileURL(configurationDirectory: configurationDirectory, id: projectID)
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else { return nil }
        return try JournalStore.openExisting(
            configurationDirectory: configurationDirectory, projectID: projectID, removalHold: hold
        )
    }

    private func confirmRemoval(id: String) -> Bool {
        output("This will, for Project \(id):") // glossary:ignore GL001
        output("- unload and delete its 3 LaunchAgents")
        output("- delete its 3 Act logs")
        output("- delete its recorded prompts and saved Project instructions")
        output("- comment on its in-flight Feature Issue, if one exists")
        output("- WIP-commit, push and remove each of its held Worktrees")
        // Lead draft, pending sponsor: confirmation names the new board effect.
        output("- complete its open Night Card")
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

    private func deleteProjectFile(id: ProjectID) -> Bool {
        let projectFile = configurationDirectory.appending(
            components: "projects", "\(id.rawValue).toml", directoryHint: .notDirectory
        )
        do {
            try FileManager.default.removeItem(at: projectFile)
            return true
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && error.code == NSFileNoSuchFileError {
            return true
        } catch {
            output("Journal removal committed, but could not delete projects/\(id.rawValue).toml: \(error)")
            output("removal incomplete; re-run `yh project remove <id>` to retry") // glossary:ignore GL001
            return false
        }
    }
}

/// What step 1 holds for the whole removal: see ``ProjectRemoval/holdForRemoval(projectID:)``.
private struct RemovalHold {
    let committed: JournalStore?
    let removal: JournalStore?
    let journalless: ProjectRemovalHold?
}
