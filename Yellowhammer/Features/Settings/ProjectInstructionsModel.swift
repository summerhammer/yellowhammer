import Config
import Domain
import Foundation
import Observation

/// One Project's instructions editor: the saved revision, the Operator's draft and what the last save did.
///
/// The app writes the text only through ``Config/ProjectInstructionsStore``, never into `config.toml`, and a
/// save launches no agent, runs no `yh`, touches no board and executes nothing. Nothing is cached beyond the
/// editor's own state and nothing watches the file: a change made elsewhere is picked up only when
/// ``reloadIfClean()`` is called (on app activation) and there is no draft to lose.
@MainActor
@Observable
final class ProjectInstructionsModel {
    /// What the last action did, for the view to word with the Project's name.
    enum Confirmation: Equatable {
        case saved(revisionID: String)
        case cleared
        case reset
        case reviewed(revisionID: String)
    }

    let projectID: ProjectID
    @ObservationIgnored private let store: ProjectInstructionsStore

    /// What is saved now, as last read or written.
    private(set) var read: ProjectInstructionsRead = .absent
    var draft = ""
    private(set) var failure: String?
    /// Set when the saved state moved since this editor loaded it; holds the state that is there now.
    private(set) var conflict: ProjectInstructionsRead?
    private(set) var confirmation: Confirmation?

    /// The text the draft started from: the saved revision's, or empty.
    private var savedText = ""

    init(project id: ProjectID, directory: URL = ConfigurationDirectory.current) {
        projectID = id
        store = ProjectInstructionsStore(
            rootDirectory: DispatchPromptStore.rootDirectory(configurationDirectory: directory), projectID: id
        )
        load()
    }

    var isDirty: Bool { draft != savedText }
    var byteCount: Int { draft.utf8.count }
    var isOverLimit: Bool { byteCount > ProjectInstructions.maximumByteCount }

    /// The saved revision, when one is saved and readable.
    var revision: ProjectInstructionsRevision? {
        if case .saved(let revision) = read { revision } else { nil }
    }

    /// Why the saved text cannot be read, when it cannot.
    var unavailableCause: String? {
        if case .unavailable(let cause) = read { cause } else { nil }
    }

    /// The families whose default changed since the saved revision was reviewed.
    var defaultChanges: [ProjectInstructionsDefaultChange] {
        revision?.defaultChanges() ?? []
    }

    var hasProblem: Bool { failure != nil || conflict != nil }

    /// Over the limit stays savable, so the store's rejection shows the limit and the count.
    var canSave: Bool {
        isDirty && unavailableCause == nil
    }

    /// The saved state a save replaces, so a save over a newer one is a conflict and not a silent overwrite.
    private var base: ProjectInstructionsUse { Self.use(of: read) }

    /// Reads the store and replaces the draft with what is saved.
    func load() {
        read = store.read()
        savedText = revision?.text ?? ""
        draft = savedText
        failure = nil
        conflict = nil
    }

    /// Reloads only when there is no draft to lose.
    func reloadIfClean() {
        guard !isDirty else { return }
        load()
    }

    /// Drops the draft and keeps the saved state.
    func discard() {
        draft = savedText
        failure = nil
        conflict = nil
    }

    /// Reloads the newer saved state, discarding the draft: the conflict's *Reload*.
    func reload() {
        confirmation = nil
        load()
    }

    /// Saves again with the state found at the conflict as the base: the conflict's *Replace*.
    @discardableResult
    func replace() -> Bool {
        guard let conflict else { return false }
        if case .unavailable(let cause) = conflict {
            failure = "The saved Project instructions cannot be read (\(cause)). Reset them, then save."
            return false
        }
        return save(replacing: Self.use(of: conflict))
    }

    /// Saves the draft. Returns whether it was written; every other outcome leaves the draft as it was.
    @discardableResult
    func save() -> Bool {
        save(replacing: base)
    }

    private func save(replacing base: ProjectInstructionsUse) -> Bool {
        confirmation = nil
        // The same composition the engine does at dispatch, built once so a save never records text the
        // prompt catalog cannot compose.
        _ = PromptCatalog.entries(projectInstructions: draft)
        switch store.save(draft, replacing: base) {
        case .saved(let revision):
            read = .saved(revision)
            savedText = revision.text
            failure = nil
            conflict = nil
            confirmation = .saved(revisionID: revision.id)
            return true
        case .cleared:
            read = .absent
            savedText = ""
            draft = ""
            failure = nil
            conflict = nil
            confirmation = .cleared
            return true
        case .tooLarge(let byteCount, let limit):
            conflict = nil
            failure = "Project instructions are \(Self.bytes(byteCount)); the limit is \(Self.bytes(limit))."
            return false
        case .failed(let cause):
            conflict = nil
            failure = cause
            return false
        case .conflict(let current):
            failure = nil
            conflict = current
            return false
        }
    }

    /// Removes the saved instructions for future dispatches, readable or not. A draft the Operator typed
    /// stays; an unedited one is cleared with the text it mirrored.
    func reset() {
        let wasDirty = isDirty
        confirmation = nil
        switch store.reset() {
        case .cleared:
            read = .absent
            savedText = ""
            if !wasDirty { draft = "" }
            failure = nil
            conflict = nil
            confirmation = .reset
        case .failed(let cause):
            failure = cause
        }
    }

    /// Records that the Operator reviewed the saved text against the current defaults.
    func markReviewed() {
        guard let revision else { return }
        confirmation = nil
        switch store.acknowledgeReview(of: revision.id) {
        case .saved(let reviewed):
            read = .saved(reviewed)
            savedText = reviewed.text
            failure = nil
            confirmation = .reviewed(revisionID: reviewed.id)
        case .conflict(let current):
            conflict = current
        case .failed(let cause):
            failure = cause
        case .cleared, .tooLarge:
            break
        }
    }

    /// The seven-character revision id the confirmation shows.
    static func shortID(_ id: String) -> String {
        String(id.prefix(7))
    }

    /// `32,768 bytes`, grouped the way the limit is written everywhere else.
    static func bytes(_ count: Int) -> String {
        "\(count.formatted(.number.locale(Locale(identifier: "en_US")))) bytes"
    }

    private static func use(of read: ProjectInstructionsRead) -> ProjectInstructionsUse {
        switch read {
        case .absent: .absent
        case .saved(let revision): .revision(revision.id)
        case .unavailable(let cause): .unavailable(cause: cause)
        }
    }
}
