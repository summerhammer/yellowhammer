import Config
import Domain
import Engine
@testable import EngineCommand
import Foundation
import Ledger
import Testing

// routing/resolve-a-route-for-a-card (P7.6): the resolver an Act is handed reads the Project's merged
// Routing Table from the Configuration loaded for that Act and the Probe verdict from the machine-wide
// Ledger — a never-probed CLI is not offered, and a CLI whose latest Probe passed is.

private struct LedgerDirectory: ~Copyable {
    let directory: URL

    init() {
        directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-routing-ledger-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}

private func route(_ cli: String, _ model: String, _ effort: String) -> Route {
    Route(cli: cli, model: model, effort: effort)!
}

private func configuration(table: RoutingTable, for projectID: ProjectID) throws -> Configuration {
    let machine = try MachineConfiguration.parse("""
        [board.linear.installations.acme]
        credential = "keychain:linear"
        workspace = "workspace-1"
        app_user = "app-user-1"

        [github]
        credential = "keychain:github"
        """, file: "config.toml")
    return Configuration(machine: machine, projects: [], invalidProjects: [], routingTables: [projectID: table])
}

private func passedProbe(cli: String) -> ProbeResult {
    ProbeResult(
        cli: cli, probedAt: Date(timeIntervalSince1970: 1_800_000_000), adapterVersion: "1", cliVersion: "1.0.0",
        findingResultFileOnCleanExit: .passed, findingUnattendedDispatch: .passed,
        findingProcessContainment: .passed, findingSessionResumption: .passed, reason: nil
    )
}

@Suite("Routing binding")
struct RoutingBindingTests {
    @Test("The resolver reads the Project's merged table and the Ledger's Probe verdict")
    func resolverIsBoundToTableAndLedger() async throws {
        let projectID = try #require(ProjectID(rawValue: "yellowhammer"))
        let table = RoutingTable(entries: [
            RoutingEntry(route: route("claude", "sonnet", "medium"), fallbacks: [route("codex", "gpt-5.4", "medium")])
        ])
        let directory = LedgerDirectory()
        let ledger = try LedgerStore.open(configurationDirectory: directory.directory)
        let resolver = try RoutingBinding.resolver(
            configuration: try configuration(table: table, for: projectID), projectID: projectID, ledger: ledger
        )
        #expect(resolver.table == table)
        let request = RouteRequest(kind: Kind("impl")!, repoRole: .backend)

        // Nothing probed yet: neither CLI is offered, and the Ledger's reason is what is recorded.
        guard case .exhausted(let exhaustion) = try resolver.resolve(request) else {
            Issue.record("expected exhausted before any Probe")
            return
        }
        #expect(exhaustion.skipped.map(\.reason) == [
            .probe("`claude` has never been probed; run `yh probe claude`"),
            .probe("`codex` has never been probed; run `yh probe codex`")
        ])

        // A passed Probe for codex offers it; claude is still excluded, so the fallback is taken.
        _ = try ledger.record(passedProbe(cli: "codex"))
        guard case .resolved(let resolved) = try resolver.resolve(request) else {
            Issue.record("expected resolved after the Probe")
            return
        }
        #expect(resolved.route == route("codex", "gpt-5.4", "medium"))
        #expect(resolved.skipped.map(\.route) == [route("claude", "sonnet", "medium")])
    }

    @Test("A Project with no merged table is refused, not routed on an empty one")
    func unloadedProjectIsRefused() async throws {
        let projectID = try #require(ProjectID(rawValue: "yellowhammer"))
        let other = try #require(ProjectID(rawValue: "other"))
        let directory = LedgerDirectory()
        let ledger = try LedgerStore.open(configurationDirectory: directory.directory)
        let configuration = try configuration(table: RoutingTable(entries: []), for: projectID)

        #expect(throws: RoutingBindingError.projectNotLoaded(other)) {
            try RoutingBinding.resolver(configuration: configuration, projectID: other, ledger: ledger)
        }
    }
}
