import Config
import Domain
import Foundation
import Observation

/// The machine-wide Operator identity — `config.toml`'s `[board.linear.installations.<name>].operator` — editable from the Settings
/// window's General pane (P18.16). The candidates come from running the bundled `yh` (`SetupInvocation
/// .choicesArguments`), never from a Board adapter of the app's own (ADR-001); the write is a textual edit
/// of `config.toml` through the loader, which leaves every other line untouched.
@MainActor
@Observable
final class OperatorIdentityModel {
    let directory: URL
    let file: URL

    private(set) var originalText: String?
    /// The configured Operator identity, as `config.toml` holds it.
    private(set) var configured: BoardObjectID?
    /// The local name of the App Installation ``configured`` belongs to; nil when `config.toml` declares
    /// no installation, or more than one.
    private(set) var installationName: String?
    /// Whether `config.toml` does not exist yet, so there is nothing to edit.
    private(set) var configMissing = false
    /// Why `config.toml` could not be loaded, in the loader's own words.
    private(set) var loadFailure: String?

    private(set) var candidates: [SetupChoices.Member] = []
    /// The picker's selection: a candidate's id, or nil for "Choose one".
    var selection: String?
    private(set) var isFetching = false
    /// The sentence the pane shows above ``fetchFailure``: the usual cause is that Linear is not installed.
    static let fetchFailureSummary =
        "The Operator identity candidates could not be read from Linear. " // glossary:ignore GL001
            + "Install Yellowhammer in the Linear workspace first."
    /// Why the candidates could not be read, one line per line of `yh`'s output; shown monospaced.
    private(set) var fetchFailure: [String] = []
    /// Why the last ``save()`` did not write; cleared by a fresh load, a fetch or a revert.
    var failure: String?

    private let engine = SetupEngine()

    init(directory: URL = ConfigurationDirectory.current) {
        self.directory = directory
        file = directory.appending(component: "config.toml", directoryHint: .notDirectory)
        load()
    }

    /// Whether the picker differs from the configured identity. False until the candidates are fetched,
    /// since until then the picker is not shown and there is no choice to lose.
    var isDirty: Bool { !candidates.isEmpty && selection != configured?.rawValue }

    /// The candidate whose id is the configured Operator identity, when the candidates are loaded.
    var configuredCandidate: SetupChoices.Member? {
        candidates.first { $0.id == configured?.rawValue }
    }

    /// Reads `file`'s text first, then loads the whole directory substituting it in place of the file on
    /// disk, so ``originalText`` and the loaded identity always agree by construction.
    func load() {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            originalText = nil
            configured = nil
            installationName = nil
            configMissing = true
            loadFailure = nil
            return
        }
        configMissing = false
        do {
            let configuration = try Configuration.load(directory: directory, reading: file, as: text)
            originalText = text
            let sole = configuration.machine.soleLinearInstallation
            configured = sole?.operatorIdentity
            installationName = sole?.name
            loadFailure = nil
            failure = nil
        } catch {
            originalText = nil
            configured = nil
            installationName = nil
            loadFailure = error.description
        }
    }

    /// Reloads `config.toml` from disk, leaving the picker's selection alone.
    func reload() {
        load()
    }

    /// Reloads from disk only when there is nothing unsaved to lose and no fetch is running.
    func reloadIfClean() {
        guard !isDirty, !isFetching else { return }
        load()
    }

    /// Runs `yh setup --print-choices` and stores the Operator candidates, preselecting the configured one.
    func fetchCandidates() async {
        isFetching = true
        fetchFailure = []
        failure = nil
        defer { isFetching = false }
        let arguments = SetupInvocation.choicesArguments(
            // The one installation loaded from config.toml, until the settings pane offers a choice (roadmap L3.2).
            installation: installationName, githubCredential: nil
        )
        var lines: [String] = []
        do {
            let status = try await engine.run(arguments: arguments, standardInput: nil) { lines.append($0) }
            guard status == 0 else {
                fetchFailure = lines.isEmpty ? ["yh exited \(status)."] : lines
                return
            }
            guard let lastLine = lines.last(where: { !$0.isEmpty }),
                  let data = lastLine.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(SetupChoices.self, from: data)
            else {
                fetchFailure = lines + ["Yellowhammer could not read yh's response."]
                return
            }
            candidates = decoded.operatorCandidates
            selection = decoded.configuredOperator
        } catch {
            fetchFailure = ["\(error)"]
        }
    }

    /// Writes the selected candidate as `[board.linear.installations.<name>].operator`. On success the model reloads from disk. On
    /// refusal the selection is kept exactly as the Operator left it.
    func save() {
        guard let selection, let originalText else { return }
        guard let installationName else {
            failure = "config.toml has no Linear App Installation. Run the Linear install again to create it."
            return
        }
        let edited = MachineConfiguration.settingOperator(
            BoardObjectID(rawValue: selection), installation: installationName, inFileText: originalText
        )
        guard edited != originalText else {
            if configured?.rawValue != selection {
                failure = "config.toml has no Linear App Installation. Run the Linear install again to create it."
            }
            return
        }
        do {
            try Configuration.save(edited, to: file, in: directory, replacing: originalText)
            load()
        } catch {
            failure = error.description
        }
    }

    /// Discards the unsaved choice, restoring the configured Operator identity.
    func revert() {
        selection = configured?.rawValue
        failure = nil
    }

    /// Terminates the running `yh`, if any: closing the Settings window is not an Act.
    func terminate() {
        engine.terminate()
    }
}
