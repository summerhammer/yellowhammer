import Config
import Domain
import Engine
import Foundation
import Ledger
import Repositories

/// Wires the author Act's selection and authoring (roadmap P9.11), beside ``CardRunBinding``: the same
/// ``RoutingBinding`` resolver, the same Dispatch choice — ``RehearsalDispatch`` in a rehearsal Night,
/// ``CLIAdapterDispatch`` otherwise — and the one routed-dispatch helper both passes share.
enum AuthoringBinding {
    static func authoring(
        mode: NightMode,
        configuration: Configuration,
        project: ProjectConfiguration,
        configurationDirectory: URL,
        refresher: MainlineRefresher,
        resultFixtures: RehearsalScript = RehearsalScript.empty
    ) throws -> FeatureSelection {
        let ledger = try LedgerStore.open(configurationDirectory: configurationDirectory)
        let resolver = try RoutingBinding.resolver(configuration: configuration, projectID: project.id, ledger: ledger)
        let route = AuthoringRoute(
            resolver: resolver,
            dispatch: DispatchBinding.dispatch(
                mode: mode, configuration: configuration, project: project,
                configurationDirectory: configurationDirectory, resultFixtures: resultFixtures
            )
        )
        return FeatureSelection(
            selector: RoutedFeatureSelector(route: route),
            transaction: AuthoringTransaction(
                drafting: RoutedFeatureBreakdown(route: route),
                citations: MainlineReader(refresher: refresher),
                transcribing: MainlineReader(refresher: refresher),
                provenance: ProvenanceDiffTester(),
                consecutiveRefusalsMax: project.bounds.consecutiveRefusalsMax,
                failedAdoptionsMax: project.bounds.failedAdoptionsMax
            ),
            reselectionsMax: project.bounds.reselectionsMax
        )
    }
}
