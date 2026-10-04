import Config
import Domain
import Foundation
import Ledger
import Observation

/// The machine-wide "Agent CLIs" window's model (P14.4). Not Project-scoped: the declared agent CLIs
/// and the Ledger are both machine-wide, so one Probe run serves every Project. Lists `config.toml`'s
/// `[cli.<name>]` entries and, for each, its latest Probe Result read from the Ledger, and lets the
/// Operator run `yh probe <cli>` on demand. It also declares a registered CLI Adapter not yet in
/// `config.toml` (#281), written through the loader as the base Routing Table pane writes — creating
/// `config.toml` when it does not exist yet, so a fresh Mac can declare its first CLI before any Linear
/// App Installation, which the Add Project sheet makes only once a route exists. It removes a declared CLI
/// the same way; the loader refuses the removal while any route, base or a Project's, still names it. The app itself
/// never probes and never writes the Ledger — `yh` does; this model only shells out to it and re-reads.
@MainActor
@Observable
final class AgentCLIModel {
    let directory: URL
    let file: URL

    /// One declared CLI Adapter, joined with its Ledger history.
    struct CLIRow: Identifiable {
        let name: String
        var id: String { name }
        /// The most recent Probe Result, nil when the CLI has never been probed.
        var latest: ProbeResult?
        /// Drift from the Probe Result immediately before `latest`, nil when there is no earlier
        /// result or nothing regressed.
        var drift: ProbeDrift?
        var eligibility: RouteTargetEligibility?
        /// The Ledger's own words, when its history could not be read for a reason other than
        /// "never probed" (e.g. a schema newer than this build knows).
        var ledgerFailure: String?
    }

    private(set) var rows: [CLIRow]?
    /// `config.toml`'s text as last loaded, what a declaration is saved against; nil while it does not exist.
    private(set) var originalText: String?
    /// The loaded machine file, carried through so a declaration re-renders it whole.
    private(set) var machine: MachineConfiguration?
    /// Set when `config.toml` exists but could not be loaded, in the loader's own words.
    private(set) var loadFailure: String?
    /// Set when `config.toml` does not exist at all: no agent CLI is declared, and declaring one creates it.
    private(set) var configMissing = false
    /// Why the last ``declare(name:executable:)`` did not write, in the loader's own words; cleared by a
    /// successful load or declaration.
    private(set) var declareFailure: String?
    /// Why the last ``remove(name:)`` of each CLI did not write, in the loader's own words, keyed by the
    /// CLI's name; cleared by a successful load.
    private(set) var removeFailures: [String: String] = [:]

    private(set) var probeLog: [String] = []
    private(set) var probeExitStatus: Int32?
    private(set) var isProbing = false
    private(set) var runningCLI: String?

    /// Also used to run `yh probe`, alongside its Setup wizard use — one process-running seam the app
    /// shells the bundled `yh` out through, never doing the Board or Probe work itself.
    private let engine = SetupEngine()

    init(directory: URL = ConfigurationDirectory.current) {
        self.directory = directory
        file = directory.appending(component: "config.toml", directoryHint: .notDirectory)
        load()
    }

    /// Reloads the declared CLIs from `config.toml` and each one's Ledger history. The Ledger is
    /// opened read-only and re-opened fresh on every call: nothing here outlives one load ("Nothing
    /// resident").
    func load() {
        guard FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else {
            clear()
            configMissing = true
            machine = .unconfigured
            rows = []
            return
        }
        configMissing = false
        let text: String
        do {
            text = try String(contentsOf: file, encoding: .utf8)
        } catch {
            clear()
            loadFailure = "\(file.path(percentEncoded: false)) could not be read: \(error.localizedDescription)"
            return
        }
        do {
            let configuration = try Configuration.load(directory: directory, reading: file, as: text)
            originalText = text
            machine = configuration.machine
            loadFailure = nil
            declareFailure = nil
            removeFailures = [:]
            rows = configuration.machine.cliAdapters.map { loadRow(name: $0.name) }
        } catch {
            clear()
            loadFailure = error.description
        }
    }

    /// The registered CLI Adapter names not yet declared: the only names the app offers.
    var declarableNames: [String] { machine?.declarableCLIAdapters ?? [] }

    /// Whether some base route names a declared CLI.
    var hasRoute: Bool { machine?.hasRouteToDeclaredCLI ?? false }

    /// Declares `name` (with an optional `executable`) and writes `config.toml` through the loader, then
    /// reloads. Declaring does not probe.
    func declare(name: String, executable: String) {
        guard let machine else { return }
        do {
            try Configuration.save(
                machine.declaring(cliAdapter: name, executable: executable).renderedTOML,
                to: file, in: directory, replacing: originalText
            )
            load()
        } catch {
            declareFailure = error.description
        }
    }

    /// Whether a base route names `name`: removing it then needs that route changed first.
    func isRouted(_ name: String) -> Bool {
        machine?.baseRoutingTableNames(cliAdapter: name) ?? false
    }

    /// Removes `name`'s declaration and writes `config.toml` through the loader, then reloads. Its Probe
    /// Results stay in the Ledger, which only `yh` writes.
    func remove(name: String) {
        guard let machine else { return }
        do {
            try Configuration.save(
                machine.removing(cliAdapter: name).renderedTOML,
                to: file, in: directory, replacing: originalText
            )
            load()
        } catch {
            removeFailures[name] = error.description
        }
    }

    private func clear() {
        originalText = nil
        machine = nil
        rows = nil
        loadFailure = nil
        declareFailure = nil
        removeFailures = [:]
    }

    /// Reloads unless a Probe is running: a running Probe still has nothing to lose (a declaration being
    /// typed lives in the view, not here), but its own reload once it exits is what should refresh the row.
    func reloadIfIdle() {
        guard !isProbing else { return }
        load()
    }

    /// Runs `yh probe <cli>`, streaming merged output into ``probeLog``, then reloads so the row
    /// reflects the new Ledger entry. Every Probe button stays disabled (via ``isProbing``) while one
    /// runs.
    func probe(cli: String) async {
        guard !isProbing else { return }
        isProbing = true
        runningCLI = cli
        probeLog = []
        probeExitStatus = nil
        defer { isProbing = false; runningCLI = nil }
        do {
            let status = try await engine.run(arguments: ["probe", cli]) { [weak self] line in
                self?.probeLog.append(line)
            }
            probeExitStatus = status
        } catch {
            probeLog.append("\(error)")
            probeExitStatus = -1
        }
        load()
    }

    private func loadRow(name: String) -> CLIRow {
        let fileURL = LedgerStore.defaultFileURL(configurationDirectory: directory)
        do {
            let store = try LedgerStore.openReadOnly(at: fileURL)
            let history = try store.probeResults(cli: name)
            let latest = history.first
            let previous = history.dropFirst().first
            let drift = latest.flatMap { current in previous.flatMap(current.drift(since:)) }
            let eligibility = try store.routeTargetEligibility(cli: name)
            return CLIRow(name: name, latest: latest, drift: drift, eligibility: eligibility, ledgerFailure: nil)
        } catch LedgerError.missing {
            // Nothing has ever been probed on this machine: every declared CLI is "never probed", not
            // an error.
            return CLIRow(
                name: name, latest: nil, drift: nil,
                eligibility: .excluded(reason: "`\(name)` has never been probed; run `yh probe \(name)`"),
                ledgerFailure: nil
            )
        } catch let error as LedgerError {
            return CLIRow(name: name, latest: nil, drift: nil, eligibility: nil, ledgerFailure: error.description)
        } catch {
            return CLIRow(name: name, latest: nil, drift: nil, eligibility: nil, ledgerFailure: "\(error)")
        }
    }
}
