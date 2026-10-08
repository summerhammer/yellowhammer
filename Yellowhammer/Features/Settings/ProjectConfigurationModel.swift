import Config
import Domain
import Foundation
import Observation

/// One Project's configuration form: `projects/<id>.toml`, editable through ``ProjectFileDraft`` (P14.3).
///
/// The app writes configuration only through ``Config/Configuration/save(_:to:in:replacing:)`` — never
/// any other file — and the Journal is never touched here. Nothing is cached beyond the form's own
/// state and nothing watches the file: a direct hand edit is picked up only when ``reloadIfClean()`` is
/// called (on app activation) and there are no unsaved edits to lose.
@MainActor
@Observable
final class ProjectConfigurationModel {
    let projectID: ProjectID
    let directory: URL
    let file: URL
    let codeHosting: CodeHostingConnectionsModel
    var selectedCodeHostingConnection = ""
    private(set) var isChangingCodeHosting = false
    private(set) var codeHostingFailure: String?
    @ObservationIgnored private let codeHostingEngine = SetupEngine()

    /// The text on disk when this model last loaded successfully, used by
    /// ``Config/Configuration/save(_:to:in:replacing:)`` to detect a concurrent hand edit.
    private(set) var originalText: String?
    /// The draft as loaded, unedited — compared against ``draft`` for ``isDirty``.
    private(set) var saved: ProjectFileDraft?
    var draft: ProjectFileDraft?
    /// The Project as last loaded from disk: what a Night runs against, unsaved edits excluded.
    private(set) var loaded: ProjectConfiguration?
    /// Declared CLIs and their configured executables, shared with the Project's Routing Entry editor.
    private(set) var routingCatalog = RoutingCatalog.empty

    /// Why the Project could not be loaded, in the loader's own words: the file does not exist, the
    /// machine file (which every Project's load depends on) is broken, or this Project's own file was
    /// refused. Never a second, app-authored opinion of what is wrong — the Operator fixes the TOML
    /// directly, guided by this message.
    private(set) var loadFailure: String?
    /// Why the last ``save()`` did not write, in the loader's own words; cleared by a fresh load.
    var failure: String?

    init(project id: ProjectID, directory: URL = ConfigurationDirectory.current) {
        codeHosting = CodeHostingConnectionsModel(directory: directory)
        projectID = id
        self.directory = directory
        file = directory.appending(
            components: "projects", "\(id.rawValue).toml", directoryHint: .notDirectory
        )
        load()
    }

    var isDirty: Bool {
        guard let saved, let draft else { return false }
        return saved != draft
    }

    /// Reads `file`'s text first, then loads the whole directory substituting it in place of the file
    /// on disk, so ``originalText`` and the loaded draft always agree by construction — never re-read
    /// separately, which could race a concurrent hand edit.
    func load() {
        codeHosting.reloadIfClean()
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            clear(loadFailure: "\(file.path(percentEncoded: false)) does not exist.")
            return
        }
        do {
            let configuration = try Configuration.load(directory: directory, reading: file, as: text)
            if let project = configuration.projects.first(where: { $0.id == projectID }) {
                originalText = text
                loaded = project
                selectedCodeHostingConnection = project.codeHostingConnectionName
                routingCatalog = RoutingCatalog(machine: configuration.machine, projects: configuration.projects)
                let loadedDraft = ProjectFileDraft(project)
                saved = loadedDraft
                draft = loadedDraft
                loadFailure = nil
                failure = nil
            } else if let invalid = configuration.invalidProjects.first(where: {
                $0.file == file.path(percentEncoded: false)
            }) {
                clear(loadFailure: invalid.errors.map(\.description).joined(separator: "\n"))
            } else {
                clear(loadFailure: "\(file.path(percentEncoded: false)) does not declare Project "
                    + "\u{201c}\(projectID.rawValue)\u{201d}.")
            }
        } catch {
            clear(loadFailure: error.description)
        }
    }

    /// Validates and writes ``draft`` through the loader. On success the model reloads from disk, so
    /// ``originalText`` and ``saved`` reflect what was actually written. On refusal ``draft`` is kept
    /// exactly as the Operator left it, so they can fix it without retyping. Returns whether the file was
    /// written, so a caller that shows the configuration elsewhere can read it again.
    @discardableResult
    func save() -> Bool {
        guard !isChangingCodeHosting, let draft, let originalText else { return false }
        do {
            try Configuration.save(draft.renderedTOML, to: file, in: directory, replacing: originalText)
            load()
            return true
        } catch {
            failure = error.description
            return false
        }
    }

    /// Discards unsaved edits, restoring the last-loaded draft.
    func revert() {
        draft = saved
        failure = nil
    }

    /// Reloads from disk only when there is nothing unsaved to lose, so a direct TOML edit shows up
    /// without ever discarding a form edit the Operator has not saved.
    func reloadIfClean() {
        guard !isDirty, !isChangingCodeHosting else { return }
        load()
    }

    /// Runs the engine's checked change, then updates only this field in the unsaved form.
    @discardableResult
    func changeCodeHostingConnection() async -> Bool {
        guard !isChangingCodeHosting, let originalText, let saved,
              !ConfigurationDirectory.isOverridden || SetupEngine.isStubbed else { return false }
        let selection = selectedCodeHostingConnection
        guard selection != saved.codeHostingConnectionName else { return false }
        guard (try? String(contentsOf: file, encoding: .utf8)) == originalText else {
            codeHostingFailure = "The Project file changed on disk. "
                + "Reload it before changing the Code Hosting Connection."
            return false
        }
        isChangingCodeHosting = true
        codeHostingFailure = nil
        defer { isChangingCodeHosting = false }
        var lines: [String] = []
        do {
            let status = try await codeHostingEngine.run(
                arguments: SetupInvocation.setProjectCodeHostingConnectionArguments(
                    project: projectID.rawValue, connection: selection
                )
            ) { lines.append($0) }
            guard status == 0 else {
                codeHostingFailure = lines.isEmpty ? "yh exited \(status)." : lines.joined(separator: "\n")
                return false
            }
            // Keep the expected original, not an arbitrary reread: any concurrent file edit still
            // refuses the next form Save. Edits typed during the engine run stay in the draft.
            self.originalText = ProjectConfiguration.settingCodeHostingConnection(
                named: selection, inFileText: originalText
            )
            self.saved?.codeHostingConnectionName = selection
            draft?.codeHostingConnectionName = selection
            if let configuration = try? Configuration.load(directory: directory) {
                loaded = configuration.projects.first { $0.id == projectID }
            }
            codeHosting.load()
            await codeHosting.refreshReport()
            return true
        } catch {
            codeHostingFailure = "\(error)"
            return false
        }
    }

    private func clear(loadFailure: String) {
        originalText = nil
        loaded = nil
        routingCatalog = .empty
        saved = nil
        draft = nil
        self.loadFailure = loadFailure
        failure = nil
    }
}
