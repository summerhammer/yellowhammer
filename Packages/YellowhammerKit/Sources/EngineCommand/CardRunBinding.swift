import Config
import Domain
import Engine
import Foundation
import Journal
import Ledger

/// The Check seam's stand-in until the engine-run Check lands (roadmap P8.5): a repository that declared
/// `check = "none"` reports it, and any other Check throws rather than reporting a green it did not run.
struct PendingRepositoryCheck: RepositoryCheckRunning {
    func run(repository: String, check: Check, worktreePath: String) async throws -> RepositoryCheckResult {
        switch check {
        case .none:
            return .declaredNone
        case .command:
            throw RepositoryCheckPendingError(repository: repository)
        }
    }
}

struct RepositoryCheckPendingError: Error, Equatable, Sendable, CustomStringConvertible {
    let repository: String

    var description: String {
        "Running the Check for repository '\(repository)' is not implemented yet (roadmap P8.5); "
            + "the Card run stopped before reporting a pass it did not earn"
    }
}

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
        return CardRun(resolver: resolver, dispatch: dispatch, check: PendingRepositoryCheck(), checks: checks)
    }
}
