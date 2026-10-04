import Domain
import Foundation
import Observation

/// The Linear App Installation's browser-install state (P17.7; spec: board-projection/install-the-linear-app),
/// shared by the Setup wizard's Linear step and the Settings window's Boards pane. Every piece of copy the
/// Operator sees for a running attempt comes from `yh setup --install-linear --events json`'s NDJSON stream,
/// decoded with `Domain.LinearInstallEvent` — the app invents no wording of its own for what an attempt is
/// doing or why it stopped. The model owns its own `SetupEngine` and install `Task`.
@MainActor
@Observable
final class LinearInstallationModel {
    enum Phase: Equatable {
        /// Checking whether an installation already exists (`yh doctor --check linear --json`, on the
        /// first appearance of the model's view).
        case checking
        case notInstalled
        /// The admin statement was shown; the browser has not yet reported back.
        case installing(adminStatement: String)
        case awaitingApproval(adminStatement: String)
        /// The Code Relay issued an approval link (roadmap P17.9): `instruction` is the event's own text
        /// with its trailing URL line removed (or the whole text, if it did not end with the URL);
        /// `link` is the URL itself, shown separately so it can be copied on its own.
        case awaitingRemoteApproval(adminStatement: String, instruction: String, link: String)
        case portsBusy(text: String, ports: [LinearInstallEvent.PortRow])
        /// `cancelled`/`notCompleted`/`differentWorkspace`/`other`/`expired`/`rejected`/
        /// `relayUnreachable`/`relayRateLimited`, or the process ended without a terminal event (killed,
        /// or exited non-zero unexpectedly, in which case `reason` is `nil`). `wasRemote` is whether this
        /// attempt was the remote-approval path, so the view can offer the right retry.
        case failed(text: String, reason: LinearInstallEvent.FailureReason?, wasRemote: Bool)
        case installed(workspaceName: String?)

        var isInstalled: Bool {
            if case .installed = self { return true }
            return false
        }
    }

    private(set) var phase: Phase = .checking
    /// Whether the running (or most recently ended) attempt used `--remote` (roadmap P17.9) — so a
    /// same-path retry (`startLinearInstall()`, no argument) repeats it.
    private(set) var lastLinearInstallWasRemote = false
    /// The registry entry passed as `--installation` (a re-connect target); nil connects untargeted.
    let installationName: String?
    /// Called once an attempt has installed and `yh` has exited, so an owner that outlives the view (the Settings
    /// window's Linear workspaces list) can reload without a view being on screen.
    var onInstalled: (@MainActor () -> Void)?
    /// The local name of the registry entry the most recent attempt installed into, from its `installed`
    /// event: a new entry, or the existing one a re-connect replaced. nil until an attempt installs.
    private(set) var installedInstallationName: String?

    private let engine = SetupEngine()
    private var installTask: Task<Void, Never>?

    /// Creates an installation model with an optional starting phase.
    /// `phase` lets a preview start past `.checking`, so its view never runs `yh`.
    init(installation: String? = nil, phase: Phase = .checking) {
        installationName = installation
        self.phase = phase
    }

    /// Runs on the first appearance of the view: an existing installation that still authorizes needs no
    /// browser round trip at all. A no-op unless the phase is still `.checking`. `yh` always reads the real
    /// configuration, so while the app is pointed at another one (a UI test's fixture) the check is not run
    /// unless a stub stands in for `yh`, as `OverviewModel` does for `yh doctor`.
    func checkExistingLinearInstallation() async {
        guard case .checking = phase else { return }
        guard !ConfigurationDirectory.isOverridden || SetupEngine.isStubbed else {
            phase = .notInstalled
            return
        }
        var lines: [String] = []
        let status = try? await engine.run(arguments: ["doctor", "--check", "linear", "--json"]) {
            lines.append($0)
        }
        guard status != nil, let findings = DoctorFindingRow.decodeLastLine(lines) else {
            phase = .notInstalled
            return
        }
        switch LinearInstallationStatus.interpret(findings, installation: installationName) {
        case .connected:
            phase = .installed(workspaceName: nil)
        case .authorizationFailed(let message):
            phase = .failed(text: message, reason: nil, wasRemote: false)
        case .noTokenPair, .unknown:
            // No "authorization" finding means the installation check is what failed: no token pair yet.
            phase = .notInstalled
        }
    }

    /// Starts one attempt: `yh setup --install-linear --events json`, with `--remote` when `remote` is
    /// set (roadmap P17.9). Remembers `remote` so a same-path retry (`startLinearInstall()`, no
    /// argument) repeats the mode this attempt used, rather than always falling back to local.
    func startLinearInstall(remote: Bool = false) {
        lastLinearInstallWasRemote = remote
        phase = .installing(adminStatement: "")
        installTask = Task { [weak self] in
            await self?.runLinearInstall(remote: remote)
        }
    }

    /// The Operator's own Cancel while awaiting approval terminates the child process — setup is not an
    /// Act, so nothing here survives past this session.
    func cancelLinearInstall() {
        installTask?.cancel()
        engine.terminate()
        phase = .failed(text: "Cancelled.", reason: nil, wasRemote: lastLinearInstallWasRemote)
    }

    /// Closing the window that owns the model: cancels the task and terminates the child, leaving the
    /// phase alone.
    func terminate() {
        installTask?.cancel()
        engine.terminate()
    }

    private func runLinearInstall(remote: Bool) async {
        let arguments = SetupInvocation.installLinearArguments(installation: installationName, remote: remote)
        do {
            let status = try await engine.run(arguments: arguments) { [weak self] line in
                self?.handleLinearInstallLine(line)
            }
            if status != 0, !phase.isInstalled, !isTerminalPhase {
                phase = .failed(text: "yh exited \(status).", reason: nil, wasRemote: remote)
            }
            // After the process ended, so the configuration it wrote is complete when the owner reloads.
            if status == 0, phase.isInstalled { onInstalled?() }
        } catch {
            phase = .failed(text: "\(error)", reason: nil, wasRemote: remote)
        }
    }

    private var isTerminalPhase: Bool {
        switch phase {
        case .portsBusy, .failed: true
        case .checking, .notInstalled, .installing, .awaitingApproval, .awaitingRemoteApproval, .installed: false
        }
    }

    private func handleLinearInstallLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let event = try? JSONDecoder().decode(LinearInstallEvent.self, from: data)
        else {
            return
        }
        switch event {
        case .adminStatement(let text):
            phase = .installing(adminStatement: text)
        case .browserOpened:
            break // The admin statement already carries everything worth showing at this point.
        case .awaitingApproval:
            phase = .awaitingApproval(adminStatement: currentAdminStatement)
        case .approvalLinkIssued(let url, _, let text):
            handleApprovalLinkIssued(url: url, text: text)
        case .awaitingRemoteApproval:
            break // `awaitingRemoteApproval` (the phase) already carries everything worth showing.
        case .portsBusy(let ports, let text):
            phase = .portsBusy(text: text, ports: ports)
        case .failed(let reason, let text):
            handleFailed(reason: reason, text: text)
        case .installed(let workspaceName, let installation):
            installedInstallationName = installation
            phase = .installed(workspaceName: workspaceName)
        }
    }

    /// The admin statement shown so far, carried over from `.installing` into `.awaitingApproval`/
    /// `.awaitingRemoteApproval` — empty if the browser/relay event arrived before any statement did.
    private var currentAdminStatement: String {
        if case .installing(let text) = phase { return text }
        return ""
    }

    private func handleApprovalLinkIssued(url: String, text: String) {
        phase = .awaitingRemoteApproval(
            adminStatement: currentAdminStatement,
            instruction: Self.instruction(fromApprovalLinkText: text, url: url), link: url
        )
    }

    private func handleFailed(reason: LinearInstallEvent.FailureReason, text: String) {
        // Under `--events json`, `portsBusy` is always followed immediately by
        // `failed(reason: .portsBusy)` — the CLI's own signal that the attempt ended, never a richer
        // report than `portsBusy` already gave. The ports-busy UI (with its own Retry) stays.
        if reason == .portsBusy, case .portsBusy = phase {
            return
        }
        phase = .failed(text: text, reason: reason, wasRemote: lastLinearInstallWasRemote)
    }

    /// `text` (`approvalLinkIssued`'s own copy) with its trailing `\n<url>` line removed, since the link
    /// is shown as its own selectable element; the whole text, unaltered, if it did not end with `url`.
    private static func instruction(fromApprovalLinkText text: String, url: String) -> String {
        let suffix = "\n\(url)"
        guard text.hasSuffix(suffix) else { return text }
        return String(text.dropLast(suffix.count))
    }
}
