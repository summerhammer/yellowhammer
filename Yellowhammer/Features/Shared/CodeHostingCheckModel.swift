import Domain
import Observation

/// An engine-owned push verdict for a selected connection and the draft's working Repos.
@MainActor
@Observable
final class CodeHostingCheckModel {
    private(set) var report: GitHubCredentialReport?
    private(set) var failure: [String] = []
    private(set) var isChecking = false
    @ObservationIgnored var onReport: (@MainActor (GitHubCredentialReport, String, [String]) -> Void)?
    @ObservationIgnored private var engine = SetupEngine()
    @ObservationIgnored private var generation = 0

    func check(connection: String?, repoPaths: [String]) async {
        generation += 1
        let current = generation
        engine.terminate()
        let runner = SetupEngine()
        engine = runner
        report = nil
        failure = []
        isChecking = false
        guard let connection, !ConfigurationDirectory.isOverridden || SetupEngine.isStubbed else { return }
        isChecking = true
        defer { if current == generation { isChecking = false } }
        var lines: [String] = []
        do {
            let status = try await runner.run(arguments: SetupInvocation.checkCodeHostingCredentialArguments(
                connection: connection, repoPaths: repoPaths
            )) { lines.append($0) }
            guard current == generation else { return }
            if status == 0, let result = GitHubCredentialReport.decodeLastLine(lines) {
                report = result
                onReport?(result, connection, repoPaths)
            } else {
                failure = lines.isEmpty ? ["yh exited \(status)."] : lines
            }
        } catch {
            guard current == generation else { return }
            failure = ["\(error)"]
        }
    }

    func terminate() {
        generation += 1
        engine.terminate()
        isChecking = false
    }
}
