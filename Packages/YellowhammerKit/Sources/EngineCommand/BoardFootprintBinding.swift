import Config
import Domain
import Engine
import Foundation
import Journal

/// Opens the footprint store for a Project's board work outside an Act (`yh setup`, `yh doctor`): the
/// Project's own Journal, which holds the persisted ids of its two custom states and three `Card Type`
/// labels (board-projection/provision-the-board, P22.8).
enum BoardFootprintBinding {
    /// Setup and `yh doctor --fix`: opens the Journal, creating it when the Project has none yet, so the
    /// ids setup creates are recorded. Nil, with `reason`, when the Journal cannot be opened (an older
    /// schema must be deleted first): the run then proceeds with an empty store and records nothing.
    static func writable(
        configurationDirectory: URL, project: ProjectConfiguration, workspace: BoardObjectID
    ) -> (store: any BoardFootprintStore, openFailure: String?) {
        do {
            let journal = try JournalStore.open(
                configurationDirectory: configurationDirectory, projectID: project.id, linearWorkspace: workspace
            )
            return (journal, nil)
        } catch {
            return (InMemoryBoardFootprintStore(), "\(error)")
        }
    }

    /// `yh doctor` without `--fix`: reads an existing Journal, never creating or writing one. A Project
    /// with no Journal yet has no persisted ids and no provenance, which is what the empty store says.
    static func readOnly(configurationDirectory: URL, projectID: ProjectID) -> any BoardFootprintStore {
        let url = JournalStore.defaultFileURL(configurationDirectory: configurationDirectory, id: projectID)
        return (try? JournalStore.openReadOnly(at: url, projectID: projectID)) ?? InMemoryBoardFootprintStore()
    }

    /// The Act's board. The real wiring binds the Project's Board Mapping and its Journal as the footprint
    /// store, so an Act never adopts a same-name state on its name alone; a test's fake board is left as it
    /// was bound.
    static func bind(
        _ bindBoard: ((Configuration, ProjectConfiguration) throws -> ActBoard)?,
        _ configuration: Configuration, _ project: ProjectConfiguration, _ journal: JournalStore, _ tracking: Bool
    ) throws -> ActBoard? {
        guard let board = try bindBoard?(configuration, project) else { return nil }
        return tracking ? board.binding(mapping: project.boardMapping, footprint: journal) : board
    }

    /// The note a Project's retired mapping keys earn, or nil: they are accepted and ignored, and never
    /// cause setup to recreate the state or group they once mapped.
    static func retiredNote(_ mapping: BoardMapping) -> String? {
        guard !mapping.retiredKeys.isEmpty else { return nil }
        let keys = mapping.retiredKeys.map { "`\($0)`" }.joined(separator: ", ")
        return "note: `[board.linear.mapping]` keys \(keys) are retired and ignored; they can be removed"
    }
}
