import Config
import Domain
import Foundation

/// The remote-approval install path (roadmap P17.9; spec: board-projection/
/// authorize-linear-via-remote-approval, ADR-006), split out of `Setup+LinearAuthorization` to keep each
/// file under its own size budget. `runLinearInstall` (in that file) decides whether to land here;
/// `runLinearRemoteInstall` shares `handleRemoteFailedAttempt`, `storeInstalled` and `report(_:text:)`
/// with the local, loopback-browser path.
extension Setup {
    /// `handleRemoteOutcome`'s own answer: retry the same remote attempt with a fresh session, or fall
    /// back to the local, loopback path (only offered on `.relayUnreachable`).
    private enum RemoteRetryDecision {
        case retry
        case switchToLocal
    }

    /// Runs the remote-approval install to completion: issues a Code Relay session, prints/emits its
    /// approval link, polls for the admin's decision, and — once approved — exchanges directly with
    /// Linear. Every non-installed outcome offers a retry (a fresh session) or, for an unreachable relay,
    /// a fallback to the local path; `--events json` never prompts, and always fails naming the reason.
    func runLinearRemoteInstall(machine: inout MachineConfiguration) async throws {
        let adminText = LinearInstallCopy.beforeRemoteApproval(teams: await candidateTeams(machine: machine))
        report(.adminStatement(text: adminText), text: adminText)

        let flow = makeRemoteFlow()
        while true {
            let outcome: LinearRemoteInstallFlow.Outcome
            do {
                outcome = try await flow.run()
            } catch let error as LinearRemoteInstallFlow.FlowError {
                throw remoteContractError(error)
            }
            if try await handleRemoteOutcome(outcome, machine: &machine) {
                continue
            }
            return
        }
    }

    /// Builds the remote flow's own events closure: NDJSON under `--events json`, or human-readable text
    /// through the boxed `output` seam otherwise.
    private func makeRemoteFlow() -> LinearRemoteInstallFlow {
        let eventsJSON = options.eventsJSON
        let emit = linearInstallEvents
        // `output` is not `@Sendable` (Setup.swift, out of this slice's scope); boxed so the flow's
        // `@Sendable` events closure can still print in human mode, exactly as `emit` already can.
        let printLine = OutputSink(output)
        return linearInstallSeams.makeRemoteFlow(events: { event in
            switch event {
            case .approvalLinkIssued(let url, let expiresIn):
                let text = LinearInstallCopy.approvalLink(url: url, expiresIn: expiresIn)
                if eventsJSON {
                    emit(.approvalLinkIssued(
                        url: url.absoluteString, expiresInSeconds: Int(expiresIn.components.seconds), text: text
                    ))
                } else {
                    printLine.write(text)
                }
            case .awaitingApproval:
                if eventsJSON {
                    emit(.awaitingRemoteApproval)
                } else {
                    printLine.write("Waiting for the admin to approve… (Ctrl-C to cancel)")
                }
            }
        })
    }

    /// `true` to retry the remote attempt from the top; `false` once `.installed` was stored, or once
    /// `.relayUnreachable` switched to (and completed via) the local path.
    private func handleRemoteOutcome(
        _ outcome: LinearRemoteInstallFlow.Outcome, machine: inout MachineConfiguration
    ) async throws -> Bool {
        switch outcome {
        case .installed(let tokens, let identity):
            try await storeInstalled(tokens: tokens, identity: identity, machine: &machine)
            return false
        case .rejected:
            try await requestNewLink(
                reason: .rejected, text: "The workspace admin declined the installation in Linear."
            )
            return true
        case .expired:
            try await requestNewLink(
                reason: .expired, text: "The approval link expired before an admin approved it."
            )
            return true
        case .notCompleted(let linearError):
            try await requestNewLink(
                reason: .notCompleted,
                text: "Linear did not complete the installation: \(linearError). "
                    + "An approval can be used only once; request a new link."
            )
            return true
        case .relayRateLimited:
            _ = try await handleRemoteFailedAttempt(
                reason: .relayRateLimited, text: "app.yellowhammer.dev is busy right now. Try again in a minute.",
                prompt: "[r]etry or [c]ancel? "
            ) { $0.hasPrefix("r") ? RemoteRetryDecision.retry : nil }
            return true
        case .relayUnreachable(let detail):
            return try await handleRelayUnreachable(detail: detail, machine: &machine)
        }
    }

    /// Shared by `.rejected`/`.expired`/`.notCompleted`: every one only ever offers "a new link", never a
    /// fallback to local sign-in.
    private func requestNewLink(reason: LinearInstallEvent.FailureReason, text: String) async throws {
        _ = try await handleRemoteFailedAttempt(
            reason: reason, text: text, prompt: "[n]ew link or [c]ancel? "
        ) { $0.hasPrefix("n") ? RemoteRetryDecision.retry : nil }
    }

    private func handleRelayUnreachable(
        detail: String, machine: inout MachineConfiguration
    ) async throws -> Bool {
        let text = "Setup could not reach app.yellowhammer.dev (\(detail)). Retry, or sign in "
            + "on this Mac as a workspace admin instead."
        let decision = try await handleRemoteFailedAttempt(
            reason: .relayUnreachable, text: text,
            prompt: "[r]etry, [l]ocal sign-in on this Mac, or [c]ancel? "
        ) { answer -> RemoteRetryDecision? in
            if answer.hasPrefix("r") { return .retry }
            return answer.hasPrefix("l") ? .switchToLocal : nil
        }
        guard case .switchToLocal = decision else { return true }
        try await runLinearLocalInstall(machine: &machine)
        return false
    }

    private func remoteContractError(_ error: LinearRemoteInstallFlow.FlowError) -> SetupError {
        switch error {
        case .relayContract(let status, let body):
            let text = "app.yellowhammer.dev answered unexpectedly (HTTP \(status)): \(body)"
            if options.eventsJSON {
                linearInstallEvents(.failed(reason: .other, text: text))
            }
            return SetupError(text)
        }
    }
}

/// Boxes `Setup.output` — a plain, non-`@Sendable` closure — so the remote flow's `@Sendable` events
/// closure can call it. Safe here: `LinearRemoteInstallFlow` invokes its `events` closure synchronously,
/// one call at a time, from the single `Task` that awaits `run()`, never concurrently.
private final class OutputSink: @unchecked Sendable {
    private let writeLine: (String) -> Void
    init(_ writeLine: @escaping (String) -> Void) { self.writeLine = writeLine }
    func write(_ line: String) { writeLine(line) }
}
