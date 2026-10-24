import Config
import Foundation

extension ActCommand {
    /// Only an Act on the default configuration directory refreshes the user's LaunchAgents: those jobs name
    /// that directory's Projects, so an Act run against any other directory (a test fixture, a scratch
    /// probe) never regenerates them.
    func run(configurationDirectory: URL) async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let isDefault = configurationDirectory.standardizedFileURL
            == Configuration.defaultDirectoryURL(homeDirectory: home).standardizedFileURL
        try await run(configurationDirectory: configurationDirectory, jobRefresh: isDefault ? .live() : nil)
    }

    /// Runs the Act. Around it, a real-mode Act regenerates its own Project's stale, idle LaunchAgents
    /// (``ScheduledJobRefresh``; Schedule Stagger Ruling item 4, issue #682): at the start, and at the end
    /// even when the Act throws, so a `[schedule]` change made while an Act ran is regenerated before the
    /// next closing firing. A rehearsal never touches LaunchAgents. A refresh failure never fails the Act.
    func run(configurationDirectory: URL, jobRefresh: ScheduledJobRefresh?) async throws {
        let refreshes = !rehearsal && jobRefresh != nil
        let projectArgument = project
        if refreshes {
            await jobRefresh?.refreshAfterResolving(projectArgument, configurationDirectory: configurationDirectory)
        }
        do {
            try await runAct(configurationDirectory: configurationDirectory)
        } catch {
            if refreshes {
                await jobRefresh?.refreshAfterResolving(projectArgument, configurationDirectory: configurationDirectory)
            }
            throw error
        }
        if refreshes {
            await jobRefresh?.refreshAfterResolving(projectArgument, configurationDirectory: configurationDirectory)
        }
    }

    private func runAct(configurationDirectory: URL) async throws {
        let invocation = try makeInvocation(
            configurationDirectory: configurationDirectory,
            now: Date(),
            bindBoard: { configuration, project in
                try BoardBinding.actBoard(machine: configuration.machine, project: project)
            },
            bindWorkspace: { WorkspaceBinding.workspace() },
            notifier: .headlessApp(),
            tracksBoardFootprint: true
        )
        // Only an Act command runs under signal handling (issue #151): a Ctrl-C at an interactive
        // `setup` prompt, or any other subcommand, keeps the default disposition. `EngineInvocation`
        // is `Sendable`, built from `self` above, so the async closure below never needs to capture
        // `self` (an `ActCommand`, not itself required to be `Sendable`).
        try await TerminationSignals.run {
            try await invocation.run()
        }
    }
}
