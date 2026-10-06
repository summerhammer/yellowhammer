import Config
import Domain
import Foundation
import Observation

/// One Board Connection's Operator identity — `config.toml`'s `[board.linear.connections.<name>].operator` —
/// editable from the Settings window's Board connections list (P18.16, L3.1). The candidates come from
/// running the bundled `yh` (`SetupInvocation.choicesArguments`) and the write is `yh config operator`
/// (`ConfigInvocation.operatorArguments`); the app reads no Board and edits no file of its own (ADR-001).
/// The model holds no configuration: the list passes the configured identity in, and reloads after a save.
@MainActor
@Observable
final class OperatorIdentityModel {
    /// The local name of the Board Connection this identity belongs to.
    let installation: String
    /// The configured Operator identity, as the list last read it from `config.toml`.
    private(set) var configured: BoardObjectID?

    private(set) var candidates: [SetupChoices.Member] = []
    /// The picker's selection: a candidate's id, or nil for "Choose one".
    var selection: String?
    private(set) var isFetching = false
    private(set) var isSaving = false
    /// The sentence the pane shows above ``fetchFailure``: the usual cause is that Linear is not installed.
    static let fetchFailureSummary =
        "The Operator identity candidates could not be read from Linear. " // glossary:ignore GL001
            + "Install Yellowhammer in the Linear workspace first."
    /// Why the candidates could not be read, one line per line of `yh`'s output; shown monospaced.
    private(set) var fetchFailure: [String] = []
    /// Why the last ``save()`` did not write, in `yh`'s own words; cleared by a fetch, a revert or a save.
    var failure: String?
    /// Called after a save `yh` accepted, so the list reloads `config.toml`.
    var onSaved: (@MainActor () -> Void)?

    private let engine = SetupEngine()

    init(installation: String, configured: BoardObjectID?) {
        self.installation = installation
        self.configured = configured
    }

    /// Whether the picker differs from the configured identity. False until the candidates are fetched,
    /// since until then the picker is not shown and there is no choice to lose.
    var isDirty: Bool { !candidates.isEmpty && selection != configured?.rawValue }

    /// The candidate whose id is the configured Operator identity, when the candidates are loaded.
    var configuredCandidate: SetupChoices.Member? {
        candidates.first { $0.id == configured?.rawValue }
    }

    /// The list read `config.toml` again: the picker's selection is left alone.
    func update(configured: BoardObjectID?) {
        self.configured = configured
    }

    /// Runs `yh setup --print-choices` and stores the Operator candidates, preselecting the configured one.
    func fetchCandidates() async {
        isFetching = true
        fetchFailure = []
        failure = nil
        defer { isFetching = false }
        let arguments = SetupInvocation.choicesArguments(boardConnection: installation, githubCredential: nil)
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

    /// Runs `yh config operator --board-connection <name> <user-id>` for the selected candidate. On success the
    /// picker is cleared (so nothing is dirty) and ``onSaved`` runs; on refusal the selection stays exactly as
    /// the Operator left it and ``failure`` carries `yh`'s own lines.
    func save() async {
        guard let selection else { return }
        isSaving = true
        failure = nil
        defer { isSaving = false }
        var lines: [String] = []
        do {
            let status = try await engine.run(
                arguments: ConfigInvocation.operatorArguments(boardConnection: installation, userID: selection)
            ) { lines.append($0) }
            guard status == 0 else {
                failure = lines.isEmpty ? "yh exited \(status)." : lines.joined(separator: "\n")
                return
            }
            candidates = []
            self.selection = nil
            onSaved?()
        } catch {
            failure = "\(error)"
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
