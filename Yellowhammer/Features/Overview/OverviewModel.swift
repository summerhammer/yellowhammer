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
///
/// Each read also runs `yh doctor --json` for the Health group's flags, beside the Journal read so a
/// slow Linear check never holds the Pulse back. The app never diagnoses anything itself.
@MainActor
@Observable
final class OverviewModel {
    /// Nil until the first read finishes, and while the configuration cannot be read. Each Project's
    /// Pulse carries its own Health flags: the installation flags are those of the App Installation that
    /// Project selected, and only probe failures (machine-wide) are on every Project.
    var snapshot: LandingSnapshot? {
        guard var read = journalSnapshot else { return nil }
        for index in read.projects.indices {
            let id = read.projects[index].id
            read.projects[index].pulse.health = findings.map { HealthFlag.flags(in: $0, for: id) }
        }
        return read
    }
    /// The Project files refused at load. The Sidebar never lists them; they are read only to explain a
    /// deep link to one of them.
    private(set) var refused: [InvalidProject] = []
    /// Why the configuration could not be read at all, in the loader's own words.
    private(set) var configurationFailure: String?

    private var journalSnapshot: LandingSnapshot?
    /// The rows of `yh doctor --json`, decoded once and filtered per Project in `snapshot`. Nil until
    /// `yh doctor` has been read, and whenever it cannot be.
    private var findings: [DoctorFindingRow]?

    /// Counts reads, so that a slow read which finishes after a newer one is dropped, not shown.
    private var generation = 0
    /// How many reads are running. Only `readOnActivation` asks.
    private var readsInFlight = 0

    func load() async {
        readsInFlight += 1
        defer { readsInFlight -= 1 }
        await readSnapshotAndHealth()
    }

    /// The read for the app becoming active: started unless a read is already running, in which case
    /// the activation is dropped, not queued. A Keychain prompt from `yh doctor` takes the app out of
    /// the foreground, and dismissing it brings the app back while that `yh doctor` still runs, so a
    /// queued activation would start another `yh doctor`, and with it another prompt, without end.
    /// Returns at once: the caller's activation loop must take the next activation while this read runs.
    func readOnActivation() {
        guard readsInFlight == 0 else { return }
        // Counted here, not in the task, so a second activation before the task starts is dropped too.
        readsInFlight += 1
        Task {
            await readSnapshotAndHealth()
            readsInFlight -= 1
        }
    }

    /// The read the Operator asks for from the toolbar. Like an activation, it is dropped while a read
    /// runs, so repeating it never stacks `yh doctor` runs.
    func readOnRequest() {
        readOnActivation()
    }

    private func readSnapshotAndHealth() async {
        generation += 1
        let current = generation
        async let findings = Self.readFindings()
        let result = await Self.read(directory: ConfigurationDirectory.current, asOf: Date())
        guard current == generation else { return }
        switch result {
        case let .success(read):
            journalSnapshot = read.snapshot
            refused = read.refused
            configurationFailure = nil
        case let .failure(error):
            journalSnapshot = nil
            refused = []
            configurationFailure = error.description
        }
        let rows = await findings
        guard current == generation else { return }
        self.findings = rows
    }

    /// The refused Project file that `id` names, if any. The file is found by its id, or by its file
    /// name when it did not decode far enough to give an id (a Project's id must match its file name).
    func refusal(for id: ProjectID) -> InvalidProject? {
        refused.first { invalid in
            invalid.id == id
                || URL(filePath: invalid.file).deletingPathExtension().lastPathComponent == id.rawValue
        }
    }

    /// Runs `yh doctor --json`, which only reads: never `--fix`, `--yes` or `--probe`, which change
    /// LaunchAgents and the Ledger. `yh` always reads the real configuration, so while the app is
    /// pointed at another one (a UI test's fixture) the flags would describe the wrong configuration,
    /// and `yh doctor` is not run unless a stub stands in for `yh`.
    private static func readFindings() async -> [DoctorFindingRow]? {
        guard !ConfigurationDirectory.isOverridden || SetupEngine.isStubbed else { return nil }
        var lines: [String] = []
        let status = try? await SetupEngine().run(arguments: ["doctor", "--json"]) { lines.append($0) }
        // A failure finding makes `yh doctor` exit non-zero; its findings are still printed.
        guard status != nil else { return nil }
        return DoctorFindingRow.decodeLastLine(lines)
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
