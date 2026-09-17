import Domain
import Foundation

/// Dispatch A (unattended dispatch + result file on clean exit) and Dispatch B (session
/// resumption): building the architect-pass instructions, running them, and classifying their
/// findings.
extension CLIProbe {
    // swiftlint:disable:next function_parameter_count
    func runDispatch(
        pass: RunPass,
        adapter: some CLIAdapter,
        route: Route,
        executable: String,
        environment: [String: String],
        worktree: URL,
        runDirectory: URL,
        instruction: String,
        resume: CLISession?
    ) async -> Result<CLIRunReport, Error> {
        let dispatch = CLIDispatch(
            route: route,
            pass: pass,
            instruction: instruction,
            worktreePath: worktree.path,
            runDirectory: runDirectory,
            timeout: dispatchTimeout,
            resume: resume,
            additionalWritableDirectories: [],
            executable: executable,
            environment: environment
        )
        let runner = CLIRunner(process: AgentCLIProcess(gracePeriod: gracePeriod, pollInterval: pollInterval))
        do {
            return .success(try await runner.run(dispatch, adapter: adapter))
        } catch {
            return .failure(error)
        }
    }

    // Dispatch B only runs when Dispatch A completed with a session; otherwise it is `.notRun`.
    // swiftlint:disable:next function_parameter_count
    func runSessionResumptionDispatch(
        adapter: some CLIAdapter,
        route: Route,
        executable: String,
        environment: [String: String],
        worktree: URL,
        runsDirectory: URL,
        dispatchA: Result<CLIRunReport, Error>,
        nonce: String
    ) async -> (ProbeFinding, String?) {
        guard case .success(let report) = dispatchA, case .exited(0) = report.end, case .completed = report.outcome,
              let session = report.session
        else {
            return (.notRun, "not run: the first dispatch did not complete with a session")
        }

        let resumeRunDirectory = runsDirectory.appendingPathComponent("resume")
        let dispatchB = await runDispatch(
            pass: .architect, adapter: adapter, route: route, executable: executable, environment: environment,
            worktree: worktree, runDirectory: resumeRunDirectory, instruction: Self.resumeInstruction, resume: session
        )
        return Self.sessionResumptionFinding(for: dispatchB, nonce: nonce)
    }

    // MARK: - Instructions

    static func unattendedInstruction(nonce: String) -> String {
        """
        This is an automated Yellowhammer probe, not real work. Do not read or modify any files \
        and do not run any command. Respond immediately with outcome `failed` and reason exactly \
        `\(nonce)`.
        """
    }

    static let resumeInstruction = """
        This is an automated Yellowhammer probe, not real work. Do not read or modify any files \
        and do not run any command. Respond immediately with outcome `failed` and reason exactly \
        equal to the reason you gave in your previous reply.
        """

    // MARK: - Classification

    static func unattendedFinding(
        for result: Result<CLIRunReport, Error>, runDirectory: URL
    ) -> (ProbeFinding, String?) {
        switch result {
        case .failure(let error):
            return (.failed, "\(error)")
        case .success(let report):
            switch report.end {
            case .exited(let status) where status == 0:
                return (.passed, nil)
            case .exited(let status):
                let tail = Self.tail(of: runDirectory, file: "stderr.log", limit: 300)
                return (.failed, "exited \(status): \(tail)")
            case .timedOut(let after, _):
                return (
                    .failed,
                    "no exit within \(after) — likely waiting on an interactive auth or permission prompt"
                )
            case .signaled, .aborted:
                return (.failed, "ended unexpectedly: \(report.end)")
            }
        }
    }

    static func resultFileFinding(for result: Result<CLIRunReport, Error>) -> (ProbeFinding, String?) {
        switch result {
        case .failure:
            return (.notRun, nil)
        case .success(let report):
            guard case .exited(0) = report.end else { return (.notRun, nil) }
            if case .completed = report.outcome {
                return (.passed, nil)
            } else {
                return (.failed, "exit 0 without a schema-valid result file: \(report.outcome)")
            }
        }
    }

    static func sessionResumptionFinding(
        for result: Result<CLIRunReport, Error>, nonce: String
    ) -> (ProbeFinding, String?) {
        switch result {
        case .failure(let error):
            return (.failed, "\(error)")
        case .success(let report):
            guard case .exited(0) = report.end, case .completed(.architect(let architectResult)) = report.outcome,
                  case .failed(let reason) = architectResult.outcome, reason.contains(nonce)
            else {
                return (.failed, "resumed session did not echo the prior reason: \(report.outcome)")
            }
            return (.passed, nil)
        }
    }

    static func tail(of runDirectory: URL, file: String, limit: Int) -> String {
        let url = runDirectory.appendingPathComponent(file)
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            return ""
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > limit ? String(trimmed.suffix(limit)) : trimmed
    }
}
