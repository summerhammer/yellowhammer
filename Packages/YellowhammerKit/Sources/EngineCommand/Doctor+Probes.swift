import Config
import Domain
import Ledger

extension Doctor {
    /// Check 2: every declared CLI Adapter's route-target eligibility, read from the Ledger
    /// (read-only, never created or migrated here). With `--probe`, runs `yh probe <cli>` for each
    /// declared CLI first. A missing Ledger fails every declared CLI as never probed.
    func runProbesCheck(machine: MachineConfiguration) async -> [DoctorFinding] {
        if probe {
            for adapter in machine.cliAdapters {
                await runProbe(adapter.name)
            }
        }

        let ledgerURL = LedgerStore.defaultFileURL(configurationDirectory: configurationDirectory)
        let store = try? LedgerStore.openReadOnly(at: ledgerURL)

        return machine.cliAdapters.map { adapter in
            guard let store else {
                return finding(
                    .probes, subject: adapter.name, .failure,
                    "`\(adapter.name)` has never been probed; run `yh probe \(adapter.name)`"
                )
            }
            do {
                switch try store.routeTargetEligibility(cli: adapter.name) {
                case .offered:
                    return finding(
                        .probes, subject: adapter.name, .pass, "`\(adapter.name)` is offered as a route target"
                    )
                case .excluded(let reason):
                    return finding(
                        .probes, subject: adapter.name, .failure,
                        "`\(adapter.name)` excluded from routing: \(reason)"
                    )
                }
            } catch {
                return finding(.probes, subject: adapter.name, .failure, "`\(adapter.name)`: \(error)")
            }
        }
    }
}
