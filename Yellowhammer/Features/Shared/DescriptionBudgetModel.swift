import Domain
import Foundation
import Observation

/// One Board Connection's `description_budget` — `config.toml`'s `[board.linear.connections.<name>]` key —
/// editable from the Settings window's Board connections list (spec `install-the-linear-app`, *budget in
/// Settings*). The write is `yh config description-budget` (`ConfigInvocation.descriptionBudgetArguments`),
/// which validates it as at load against the board's own limit; the app knows no limit, reads no Board and
/// edits no file of its own (ADR-001). The model holds no configuration: the list passes the configured value
/// in, and reloads after a save.
@MainActor
@Observable
final class DescriptionBudgetModel {
    /// The local name of the Board Connection this budget belongs to.
    let installation: String
    /// The configured budget, as the list last read it from `config.toml`; nil is the default.
    private(set) var configured: Int?
    /// The field's text.
    var draft: String
    private(set) var isSaving = false
    /// Why the last ``save()`` did not write, in `yh`'s own words; cleared by a save or a revert.
    var failure: String?
    /// Called after a save `yh` accepted, so the list reloads `config.toml`.
    var onSaved: (@MainActor () -> Void)?

    private let engine = SetupEngine()

    init(installation: String, configured: Int?) {
        self.installation = installation
        self.configured = configured
        draft = String(configured ?? DescriptionBudget.defaultValue)
    }

    /// The budget in force: the configured one, or the default.
    var effective: Int { configured ?? DescriptionBudget.defaultValue }

    /// The field's text as a number, when it is one.
    var parsedDraft: Int? { Int(draft.trimmingCharacters(in: .whitespaces)) }

    /// Whether the field holds a number that differs from the budget in force.
    var isDirty: Bool { parsedDraft.map { $0 != effective } ?? !draft.isEmpty }

    /// The list read `config.toml` again: an unsaved edit is left alone, a clean field follows the file.
    func update(configured: Int?) {
        let wasClean = !isDirty
        self.configured = configured
        if wasClean { draft = String(effective) }
    }

    /// Runs `yh config description-budget --board-connection <name> <budget>`. On success ``onSaved`` runs; on
    /// refusal the field stays exactly as the Operator left it and ``failure`` carries `yh`'s own lines.
    func save() async {
        guard let budget = parsedDraft else { return }
        isSaving = true
        failure = nil
        defer { isSaving = false }
        var lines: [String] = []
        do {
            let status = try await engine.run(
                arguments: ConfigInvocation.descriptionBudgetArguments(boardConnection: installation, budget: budget)
            ) { lines.append($0) }
            guard status == 0 else {
                failure = lines.isEmpty ? "yh exited \(status)." : lines.joined(separator: "\n")
                return
            }
            onSaved?()
        } catch {
            failure = "\(error)"
        }
    }

    /// Discards the unsaved edit.
    func revert() {
        draft = String(effective)
        failure = nil
    }

    /// Terminates the running `yh`, if any: closing the Settings window is not an Act.
    func terminate() {
        engine.terminate()
    }
}
