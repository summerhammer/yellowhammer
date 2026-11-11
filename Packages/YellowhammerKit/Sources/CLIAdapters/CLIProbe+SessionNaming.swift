import Domain
import Foundation

/// Session naming (issue #800): whether the Adapter names its sessions. Dispatch A and Dispatch B carry
/// a session name, and the Probe then reads the titles the CLI recorded for A's session. Recorded, never
/// gating — a CLI whose Adapter has no naming flag is reported here, and nothing else changes.
extension CLIProbe {
    static let unattendedSessionNameSuffix = "unattended"
    static let resumedSessionNameSuffix = "resumed"

    /// The names the Probe gives its two dispatches: A (unattended) first, B (resumed) last.
    struct ExpectedSessionNames: Equatable {
        let cli: String
        let first: String
        let last: String

        init(cli: String) {
            self.cli = cli
            first = CLIProbe.sessionName(cli: cli, dispatch: CLIProbe.unattendedSessionNameSuffix)
            last = CLIProbe.sessionName(cli: cli, dispatch: CLIProbe.resumedSessionNameSuffix)
        }
    }

    static func sessionName(cli: String, dispatch: String) -> String {
        AgentSessionName.probe(cli: cli, dispatch: dispatch)
    }

    static func unattendedRunDirectory(in context: ProbeDispatchContext) -> URL {
        context.runsDirectory.appendingPathComponent("unattended")
    }

    /// Dispatch A, named so its session can be told from Dispatch B's.
    func runUnattendedDispatch(
        adapter: some CLIAdapter, context: ProbeDispatchContext, nonce: String
    ) async -> Result<CLIRunReport, Error> {
        await runDispatch(
            pass: .architect, family: .unattendedProbe, adapter: adapter, context: context,
            runDirectory: Self.unattendedRunDirectory(in: context),
            instruction: Self.unattendedInstruction(nonce: nonce), resume: nil,
            sessionName: Self.sessionName(cli: adapter.cli, dispatch: Self.unattendedSessionNameSuffix)
        )
    }

    /// The findings of Dispatch B and of the session-naming check that follows it.
    struct SessionFindings {
        let resumption: ProbeFinding
        let resumptionDetail: String?
        let naming: ProbeFinding
        let namingDetail: String?
    }

    func runSessionDispatches(
        adapter: some CLIAdapter,
        context: ProbeDispatchContext,
        dispatchA: Result<CLIRunReport, Error>,
        nonce: String
    ) async -> SessionFindings {
        let resumed = await runSessionResumptionDispatch(
            adapter: adapter, context: context, dispatchA: dispatchA, nonce: nonce
        )
        let (naming, namingDetail) = checkSessionNaming(
            adapter: adapter, context: context, dispatchA: dispatchA, dispatchBRan: resumed.session != nil
        )
        return SessionFindings(
            resumption: resumed.outcome.0, resumptionDetail: resumed.outcome.1,
            naming: naming, namingDetail: namingDetail
        )
    }

    /// Reads the titles of Dispatch A's session, which Dispatch B resumed, and classifies them.
    func checkSessionNaming(
        adapter: some CLIAdapter,
        context: ProbeDispatchContext,
        dispatchA: Result<CLIRunReport, Error>,
        dispatchBRan: Bool
    ) -> (ProbeFinding, String?) {
        var sessionA: CLISession?
        if case .success(let report) = dispatchA {
            sessionA = report.session
        }
        var titles: [String]?
        if adapter.namesSessions, let sessionA, dispatchBRan {
            let dispatch = context.dispatch(
                pass: .architect, family: .sessionResumptionProbe, instruction: "",
                runDirectory: Self.unattendedRunDirectory(in: context),
                timeout: dispatchTimeout, resume: sessionA
            )
            titles = adapter.sessionTitles(of: sessionA, dispatch: dispatch)
        }
        return Self.sessionNamingFinding(
            namesSessions: adapter.namesSessions,
            sessionsProduced: sessionA != nil && dispatchBRan,
            titles: titles,
            expected: ExpectedSessionNames(cli: adapter.cli)
        )
    }

    static func sessionNamingFinding(
        namesSessions: Bool,
        sessionsProduced: Bool,
        titles: [String]?,
        expected: ExpectedSessionNames
    ) -> (ProbeFinding, String?) {
        let cli = expected.cli
        guard namesSessions else {
            return (
                .notRun,
                "the \(cli) Adapter has no session-naming flag, so Orca titles its sessions by their first prompt"
            )
        }
        guard sessionsProduced else {
            return (
                .notRun,
                "session naming could not be checked: the unattended or resumed dispatch produced no session"
            )
        }
        guard let titles else {
            return (.notRun, "session naming could not be checked: the \(cli) session transcript was not found")
        }
        guard titles.contains(expected.first), titles.last == expected.last else {
            let found = titles.isEmpty ? "none" : titles.map { "`\($0)`" }.joined(separator: ", ")
            return (.failed, "session naming: expected the last session title `\(expected.last)`, found \(found)")
        }
        return (.passed, nil)
    }
}
