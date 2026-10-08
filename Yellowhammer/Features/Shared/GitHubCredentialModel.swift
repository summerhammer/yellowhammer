import Domain
import Foundation
import Observation

/// The GitHub credential's state, shared by the Setup wizard's GitHub step and the Settings window's General
/// pane. The app never calls GitHub or reads the Keychain itself (ADR-001): every check is `yh setup
/// --print-github` and every store is `yh setup --install-github`, decoded with ``GitHubCredentialReport``, so
/// the wording the Operator reads comes from `yh`.
///
/// The token travels only over standard input: never an argument, never logged, and not kept here after
/// the run starts. The model owns a `SetupEngine` per run and a generation counter that drops the result of a
/// run that a newer one superseded.
@MainActor
@Observable
final class GitHubCredentialModel {
    enum State: Equatable {
        case checking
        case checked(GitHubCredentialReport)
        /// `yh`'s own lines when it exited non-zero or its last line was not a report.
        case failed([String])
    }

    private(set) var state: State
    /// Whether a store or an import is running.
    private(set) var isStoring = false
    /// `yh`'s lines when the last store or import exited non-zero; nil otherwise.
    private(set) var storeFailure: [String]?
    /// Called with each report and the Repo paths it was checked against, so an owner (the wizard's draft) can
    /// keep it.
    @ObservationIgnored var onReport: (@MainActor (GitHubCredentialReport, [String]) -> Void)?

    @ObservationIgnored private var engine = SetupEngine()
    @ObservationIgnored private var generation = 0

    /// `state` lets a preview start past `.checking`, so its view never runs `yh`.
    init(state: State = .checking) {
        self.state = state
    }

    /// `yh` reads the real configuration and Keychain, so while the app is pointed at another configuration (a
    /// UI test's fixture) it is not run unless a stub stands in for it, as the wizard's `fetchTeams` does.
    private var mayRunYH: Bool {
        !ConfigurationDirectory.isOverridden || SetupEngine.isStubbed
    }

    /// `yh setup --print-github` for `repoPaths` (none: the credential only). The reference is the one in
    /// `config.toml`.
    func check(repoPaths: [String]) async {
        // A store checks again when it ends, so a check asked for meanwhile would only supersede it.
        guard mayRunYH, !isStoring else { return }
        let run = beginRun()
        state = .checking
        var lines: [String] = []
        do {
            let status = try await run.engine.run(
                arguments: SetupInvocation.printGitHubArguments(githubCredential: nil, repoPaths: repoPaths)
            ) { lines.append($0) }
            guard run.generation == generation else { return }
            if status == 0, let report = GitHubCredentialReport.decodeLastLine(lines) {
                state = .checked(report)
                onReport?(report, repoPaths)
            } else {
                state = .failed(lines.isEmpty ? ["yh exited \(status)."] : lines)
            }
        } catch {
            guard run.generation == generation else { return }
            state = .failed(["\(error)"])
        }
    }

    /// Stores `token` (one line on `yh setup --install-github --token-stdin --replace`'s standard input), then
    /// checks again. `yh` authenticates the token before it stores it, so a rejected one is never stored.
    func store(token: String, repoPaths: [String]) async {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await install(source: .standardInput, standardInput: trimmed + "\n", repoPaths: repoPaths)
    }

    /// Stores the GitHub CLI's token (`yh setup --install-github --from-gh --replace`), then checks again.
    func importFromGitHubCLI(repoPaths: [String]) async {
        await install(source: .githubCLI, standardInput: nil, repoPaths: repoPaths)
    }

    /// Stops any run. The state is left alone.
    func terminate() {
        generation += 1
        isStoring = false
        engine.terminate()
    }

    private func install(
        source: SetupInvocation.GitHubTokenSource, standardInput: String?, repoPaths: [String]
    ) async {
        guard mayRunYH else { return }
        let run = beginRun()
        isStoring = true
        storeFailure = nil
        var lines: [String] = []
        var failure: [String]?
        do {
            let status = try await run.engine.run(
                arguments: SetupInvocation.installGitHubArguments(
                    githubCredential: nil, source: source, replace: true, repoPaths: repoPaths
                ),
                standardInput: standardInput
            ) { lines.append($0) }
            if status != 0 { failure = lines.isEmpty ? ["yh exited \(status)."] : lines }
        } catch {
            failure = ["\(error)"]
        }
        guard run.generation == generation else { return }
        isStoring = false
        storeFailure = failure
        // Whatever happened, the report is what the Operator needs next: a token stored but refused by a
        // Repo, or one that was rejected and never stored.
        await check(repoPaths: repoPaths)
    }

    /// Supersedes the current run with a new one on its own engine.
    private func beginRun() -> (engine: SetupEngine, generation: Int) {
        engine.terminate()
        let fresh = SetupEngine()
        engine = fresh
        generation += 1
        return (fresh, generation)
    }
}
