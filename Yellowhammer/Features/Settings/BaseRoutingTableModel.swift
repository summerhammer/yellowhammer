import Config
import Foundation
import Observation

/// The machine-wide base Routing Table — `config.toml`'s `[[routing]]` entries — editable, not
/// Project-scoped (P14.3). The spec calls the Routing Table "a file the Operator edits, through the app
/// or directly"; this is the app half of that. Everything else in `config.toml` (Linear authorization,
/// the machine default GitHub credential, the declared CLI Adapters) is carried through untouched: this
/// slice of the app edits only the Routing Table.
@MainActor
@Observable
final class BaseRoutingTableModel {
    let directory: URL
    let file: URL

    private(set) var originalText: String?
    private(set) var saved: [RoutingEntryDraft]?
    var routingTable: [RoutingEntryDraft]?
    /// The rest of the machine file, carried through unedited so ``save()`` can re-render it whole.
    private(set) var machine: MachineConfiguration?
    /// What the pane's controls offer, from the machine file and the Projects last loaded beside it.
    private(set) var catalog = RoutingCatalog.empty

    /// Why the base Routing Table could not be loaded, in the loader's own words.
    private(set) var loadFailure: String?
    /// Why the last ``save()`` did not write, in the loader's own words; cleared by a fresh load.
    var failure: String?

    init(directory: URL = ConfigurationDirectory.current) {
        self.directory = directory
        file = directory.appending(component: "config.toml", directoryHint: .notDirectory)
        load()
    }

    /// Why each declared CLI whose executable cannot run cannot (#377): a route naming one never dispatches.
    var executableProblems: [String] {
        machine?.cliAdapters.compactMap(\.executableProblem) ?? []
    }

    var isDirty: Bool {
        guard let saved, let routingTable else { return false }
        return saved != routingTable
    }

    /// Reads `file`'s text first, then loads the whole directory substituting it in place of the file
    /// on disk, so ``originalText`` and the loaded table always agree by construction.
    func load() {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            clear(loadFailure: "\(file.path(percentEncoded: false)) does not exist.")
            return
        }
        do {
            let configuration = try Configuration.load(directory: directory, reading: file, as: text)
            originalText = text
            machine = configuration.machine
            catalog = RoutingCatalog(machine: configuration.machine, projects: configuration.projects)
            let entries = configuration.machine.routingTable.map(RoutingEntryDraft.init)
            saved = entries
            routingTable = entries
            loadFailure = nil
            failure = nil
        } catch {
            clear(loadFailure: error.description)
        }
    }

    /// Validates and writes ``routingTable`` through the loader. On success the model reloads from
    /// disk. On refusal the table is kept exactly as the Operator left it.
    func save() {
        guard let routingTable, let originalText, let machine else { return }
        do {
            try Configuration.save(
                machine.renderedTOML(routingTable: routingTable), to: file, in: directory, replacing: originalText
            )
            load()
        } catch {
            failure = error.description
        }
    }

    /// Discards unsaved edits, restoring the last-loaded table.
    func revert() {
        routingTable = saved
        failure = nil
    }

    /// Reloads from disk only when there is nothing unsaved to lose.
    func reloadIfClean() {
        guard !isDirty else { return }
        load()
    }

    private func clear(loadFailure: String) {
        originalText = nil
        saved = nil
        routingTable = nil
        machine = nil
        catalog = .empty
        self.loadFailure = loadFailure
        failure = nil
    }
}
