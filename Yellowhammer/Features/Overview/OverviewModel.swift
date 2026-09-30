import Config
import Domain
import Foundation
import Observation
import Pulse

/// What the main window shows: every configured Project's landing snapshot, and the Project files
/// refused at load.
///
/// The model reads the configuration and the Journals each time it is asked: when the window appears
/// and whenever the app becomes active. It never watches or polls them ("Nothing resident"). The read
/// runs off the main actor, because each Journal open can wait for its busy timeout while an Act writes,
/// and the window must stay responsive during that wait.
@MainActor
@Observable
final class OverviewModel {
    /// Nil until the first read finishes, and while the configuration cannot be read.
    private(set) var snapshot: LandingSnapshot?
    /// The Project files refused at load. The Sidebar never lists them; they are read only to explain a
    /// deep link to one of them.
    private(set) var refused: [InvalidProject] = []
    /// Why the configuration could not be read at all, in the loader's own words.
    private(set) var configurationFailure: String?

    /// Counts reads, so that a slow read which finishes after a newer one is dropped, not shown.
    private var generation = 0

    func load() async {
        generation += 1
        let current = generation
        let result = await Self.read(directory: ConfigurationDirectory.current, asOf: Date())
        guard current == generation else { return }
        switch result {
        case let .success(read):
            snapshot = read.snapshot
            refused = read.refused
            configurationFailure = nil
        case let .failure(error):
            snapshot = nil
            refused = []
            configurationFailure = error.description
        }
    }

    /// The refused Project file that `id` names, if any. The file is found by its id, or by its file
    /// name when it did not decode far enough to give an id (a Project's id must match its file name).
    func refusal(for id: ProjectID) -> InvalidProject? {
        refused.first { invalid in
            invalid.id == id
                || URL(filePath: invalid.file).deletingPathExtension().lastPathComponent == id.rawValue
        }
    }

    private nonisolated struct Read: Sendable {
        let snapshot: LandingSnapshot
        let refused: [InvalidProject]
    }

    @concurrent
    private nonisolated static func read(directory: URL, asOf: Date) async -> Result<Read, ConfigurationError> {
        do {
            // A Mac where Setup has never run has no Projects to show, which is not a failure: the
            // window shows its onboarding view (scope-windows-to-a-project, AC 3).
            guard let configuration = try Configuration.loadIfSetUp(directory: directory) else {
                return .success(Read(snapshot: LandingSnapshot(projects: [], asOf: asOf), refused: []))
            }
            let snapshot = LandingSnapshot.read(
                configuration: configuration, configurationDirectory: directory, asOf: asOf
            )
            return .success(Read(snapshot: snapshot, refused: configuration.invalidProjects))
        } catch {
            return .failure(error)
        }
    }
}
