import Config
import Domain
import Engine
import Foundation
import Journal
import Ledger

/// Wires the build Act's Card run, the one place an adapter (and so the Dispatch seam's real
/// implementation) is constructed: a Rehearsal Night never dispatches an agent CLI, so it gets
/// ``RehearsalDispatch``; a real Night gets ``CLIAdapterDispatch``.
enum CardRunBinding {
    static func cardRunner(
        mode: NightMode,
        configuration: Configuration,
        project: ProjectConfiguration,
        configurationDirectory: URL
    ) throws -> CardRun {
        let ledger = try LedgerStore.open(configurationDirectory: configurationDirectory)
        let resolver = try RoutingBinding.resolver(configuration: configuration, projectID: project.id, ledger: ledger)
        let dispatch: any AgentDispatch
        switch mode {
        case .rehearsal:
            dispatch = RehearsalDispatch()
        case .real:
            var declared: [String: String] = [:]
            for adapter in configuration.machine.cliAdapters {
                declared[adapter.name] = adapter.executable
            }
            dispatch = CLIAdapterDispatch(
                runsDirectory: CLIAdapterDispatch.runsDirectory(
                    configurationDirectory: configurationDirectory, projectID: project.id
                ),
                declaredExecutables: declared
            )
        }
        var checks: [String: Check] = [:]
        for repo in project.repos {
            checks[repo.name] = repo.check
        }
        // The real Check and the real reset seam in both modes: a rehearsal Night stops at exactly
        // three boundaries (agent CLI dispatch, push, pull request), and local git is not one of them.
        return CardRun(
            resolver: resolver, dispatch: dispatch, check: WorktreeCheck(), checks: checks,
            reviewRoundsMax: project.bounds.reviewRoundsMax, attemptsPerCard: project.bounds.attemptsPerCard,
            resetting: AttemptWorktreeReset()
        )
    }
}
