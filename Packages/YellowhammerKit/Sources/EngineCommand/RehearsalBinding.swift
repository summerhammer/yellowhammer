import Config
import Domain
import Foundation
import Journal

/// Selects what one Act runs against, from its mode, at the composition root (OQ149): a real Act gets
/// the Project's own Journal and Linear project; a rehearsal Act gets the Project's declared rehearsal
/// Journal and rehearsal Linear project, or is refused before anything is opened. Nothing below here
/// knows about rehearsal: a rehearsal Night shares no Night, Feature, Cycle, Work Card, Refusal or
/// counter with the real Journal, and no issue with the real board, because it never holds either.
enum RehearsalBinding {
    /// This Project's Rehearsal Context, or ``RehearsalUnavailable`` naming what is not defined. Reads
    /// the configuration only: it opens no Journal and binds no board.
    static func context(
        project: ProjectConfiguration, configurationDirectory: URL
    ) throws(RehearsalUnavailable) -> RehearsalContext {
        try project.rehearsalContext(
            realJournal: JournalStore.defaultFileURL(configurationDirectory: configurationDirectory, id: project.id)
        )
    }

    /// The Project as the Act binds its board, and the one Journal it is given. For a rehearsal the
    /// Project's `linearProject` (read only by ``BoardBinding``) is its rehearsal Linear project, reached
    /// through the same Board Connection (OQ149 (b)), and the Journal is its rehearsal Journal; the
    /// rehearsal context is resolved, or refused, before either is touched. A creating open records the
    /// Board Connection's workspace.
    static func bind(
        _ project: ProjectConfiguration, rehearsal: Bool, machine: MachineConfiguration, in configurationDirectory: URL
    ) throws -> (project: ProjectConfiguration, journal: JournalStore) {
        guard rehearsal else {
            let journal = try JournalStore.open(
                configurationDirectory: configurationDirectory, projectID: project.id,
                linearWorkspace: BoardBinding.workspace(machine: machine, project: project)
            )
            return (project, journal)
        }
        let context = try context(project: project, configurationDirectory: configurationDirectory)
        var rehearsing = project
        rehearsing.linearProject = context.linearProject
        let journal = try JournalStore.open(
            rehearsalJournalAt: context.journal, projectID: project.id,
            linearWorkspace: BoardBinding.workspace(machine: machine, project: rehearsing)
        )
        return (rehearsing, journal)
    }
}
