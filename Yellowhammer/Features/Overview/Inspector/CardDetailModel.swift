import Domain
import Foundation
import Observation
import Pulse

/// The Inspector's Card detail for one Card of one Project: the account its own Project's Journal
/// recorded behind it (P14.5, carried into the Inspector by P18.8).
///
/// A model is made for one Card of one Project and never re-pointed, so it can never show a Card of
/// another Project, or another Card, while a read is in flight. The Journal is found by `project`
/// alone, opened read-only and dropped at the end of every read ("Nothing resident"). The model reads
/// when the Card is opened and again whenever the landing snapshot is re-read; it never watches or
/// polls the Journal.
@MainActor
@Observable
final class CardDetailModel {
    let project: ProjectID
    let issueID: String

    /// Nil until the first read lands.
    private(set) var read: CardDetailRead?

    init(project: ProjectID, issueID: String) {
        self.project = project
        self.issueID = issueID
    }

    /// Re-reads the Card's detail. A blocked read cannot be cancelled, so a read whose task was cancelled
    /// meanwhile (the Inspector closed, or a newer read started) is dropped rather than applied.
    func load() async {
        let result = await Self.read(issueID: issueID, project: project, directory: ConfigurationDirectory.current)
        guard !Task.isCancelled else { return }
        read = result
    }

    /// Off the main actor: the Journal open can wait out its busy timeout while an Act writes.
    @concurrent
    private nonisolated static func read(issueID: String, project: ProjectID, directory: URL) async -> CardDetailRead {
        CardDetail.read(issueID: issueID, project: project, configurationDirectory: directory)
    }
}
