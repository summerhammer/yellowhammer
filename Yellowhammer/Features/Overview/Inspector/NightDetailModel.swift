import Domain
import Foundation
import Observation
import Pulse

/// The Night's account for one Night of one Project: the Journal events its own Project's Journal recorded
/// for it (OQ158 ruling item 14). The main area draws them along a playhead (`NightAccountView`), and the
/// Inspector shows the Night's facts from the same read (`NightDetailView`); the window owns the model, so
/// the two columns never read the Journal twice.
///
/// A model is made for one Night of one Project and never re-pointed, so it can never show a Night of
/// another Project, or another Night, while a read is in flight. The Journal is found by `project` alone,
/// opened read-only and dropped at the end of every read ("Nothing resident"). The main area reads when the
/// Night is opened and again whenever the landing snapshot is re-read; the model never watches or polls the
/// Journal.
@MainActor
@Observable
final class NightDetailModel {
    let project: ProjectID
    let nightID: Int64

    /// Nil until the first read lands.
    private(set) var read: NightAccountRead?
    private(set) var promptIndexRead: DispatchPromptIndexRead?

    var promptIndex: DispatchPromptIndex? {
        if case let .index(index) = promptIndexRead {
            return index
        }
        return nil
    }

    init(project: ProjectID, nightID: Int64) {
        self.project = project
        self.nightID = nightID
    }

    /// Re-reads the Night's account. A blocked read cannot be cancelled, so a read whose task was cancelled
    /// meanwhile (the Inspector closed, or a newer read started) is dropped rather than applied.
    func load(asOf: Date = Date()) async {
        let directory = ConfigurationDirectory.current
        async let accountResult = Self.read(nightID: nightID, project: project, directory: directory)
        async let promptResult = Self.readPrompts(
            nightID: nightID, project: project, directory: directory, asOf: asOf
        )

        let (acc, prompts) = await (accountResult, promptResult)
        guard !Task.isCancelled else { return }
        read = acc
        promptIndexRead = prompts
    }

    /// Off the main actor: the Journal open can wait out its busy timeout while an Act writes.
    @concurrent
    private nonisolated static func read(
        nightID: Int64, project: ProjectID, directory: URL
    ) async -> NightAccountRead {
        NightAccount.read(nightID: nightID, project: project, configurationDirectory: directory)
    }

    @concurrent
    private nonisolated static func readPrompts(
        nightID: Int64, project: ProjectID, directory: URL, asOf: Date
    ) async -> DispatchPromptIndexRead {
        DispatchPromptIndex.read(
            configurationDirectory: directory, projectID: project, scope: .night(nightID: nightID), asOf: asOf
        )
    }
}
