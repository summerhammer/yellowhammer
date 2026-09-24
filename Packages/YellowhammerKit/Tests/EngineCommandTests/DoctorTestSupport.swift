import Config
import Domain
@testable import EngineCommand
import Foundation
import Repositories

/// Builds a ``Doctor`` with every seam faked or injected against a temp directory, mirroring
/// `makeSetup`. Never touches the real home directory, Keychain or launchctl.
func makeDoctor(
    directory: borrowing ConfigurationDirectory,
    board: FakeProvisioningBoard = FakeProvisioningBoard(project: nil),
    console: ScriptedConsole = ScriptedConsole(),
    credentials: RecordingCredentialStore = RecordingCredentialStore(seed: ["keychain:linear": "test-secret"]),
    output: RecordingOutput = RecordingOutput(),
    homeDirectory: URL = FileManager.default.temporaryDirectory
        .appending(component: "yh-doctor-home-\(UUID().uuidString)", directoryHint: .isDirectory),
    launchAgents: any LaunchAgentControl = RecordingLaunchAgentControl(),
    git: GitRunner = GitRunner(),
    runProbe: @escaping (String) async -> Void = { _ in },
    fix: Bool = false,
    yes: Bool = false,
    probe: Bool = false,
    checks: [DoctorCheck] = DoctorCheck.allCases
) -> Doctor {
    Doctor(
        configurationDirectory: directory.url,
        homeDirectory: homeDirectory,
        output: { output.record($0) },
        console: console,
        credentials: credentials,
        bindProvisioning: { _, _, _ in board },
        launchAgents: launchAgents,
        git: git,
        runProbe: runProbe,
        fix: fix,
        yes: yes,
        probe: probe,
        checks: checks
    )
}

/// A throwaway `git init`-only local repository: enough for `git -C <path> rev-parse
/// --is-inside-work-tree` to answer `true`, with no commit needed.
struct DoctorGitFixture: ~Copyable {
    let url: URL
    private let git = GitRunner()

    init(name: String = UUID().uuidString) {
        url = FileManager.default.temporaryDirectory.appending(component: "yh-doctor-git-\(name)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    var path: String { url.path(percentEncoded: false) }

    func initRepo() async {
        _ = await git.run(["-C", path, "init", "--initial-branch=main"])
    }
}
