import Domain
import Foundation

/// The Linear step's browser-install state (P17.7; spec: board-projection/install-the-linear-app). Every
/// piece of copy the Operator sees for a running attempt comes from `yh setup --install-linear --events
/// json`'s NDJSON stream, decoded with `Domain.LinearInstallEvent` — the app invents no wording of its
/// own for what an attempt is doing or why it stopped.
extension SetupWizardModel {
    enum LinearInstallPhase: Equatable {
        /// Checking whether an installation already exists (`yh doctor --check linear --json`, on the
        /// step's first appearance this session).
        case checking
        case notInstalled
        /// The admin statement was shown; the browser has not yet reported back.
        case installing(adminStatement: String)
        case awaitingApproval(adminStatement: String)
        case portsBusy(text: String, ports: [LinearInstallEvent.PortRow])
        /// `cancelled`/`notCompleted`/`differentWorkspace`/`other`, or the process ended without a
        /// terminal event (killed, or exited non-zero unexpectedly).
        case failed(text: String)
        case installed(workspaceName: String?)

        var isInstalled: Bool {
            if case .installed = self { return true }
            return false
        }
    }

    /// One row of `yh doctor --check linear --json`'s output — a plain local mirror, since the app does
    /// not link `EngineCommand` (only `yh` reads/writes the Keychain and the Board).
    struct DoctorFindingRow: Decodable {
        let subject: String
        let severity: String
        let message: String
    }

    /// Runs on the Linear step's first appearance this session: an existing installation that still
    /// authorizes needs no browser round trip at all.
    func checkExistingLinearInstallation() async {
        guard case .checking = linearInstallPhase else { return }
        var lines: [String] = []
        let status = try? await engine.run(arguments: ["doctor", "--check", "linear", "--json"]) {
            lines.append($0)
        }
        guard status != nil,
              let lastLine = lines.last(where: { !$0.isEmpty }),
              let data = lastLine.data(using: .utf8),
              let findings = try? JSONDecoder().decode([DoctorFindingRow].self, from: data)
        else {
            linearInstallPhase = .notInstalled
            return
        }
        guard let authorization = findings.first(where: { $0.subject == "authorization" }) else {
            // No "authorization" finding at all means the installation check (subject "installation")
            // is what failed: no token pair yet.
            linearInstallPhase = .notInstalled
            return
        }
        if authorization.severity == "pass" {
            linearInstallPhase = .installed(workspaceName: nil)
        } else {
            linearInstallPhase = .failed(text: authorization.message)
        }
    }

    /// Starts one attempt: `yh setup --install-linear --events json`. Retry (a busy port, or a failed
    /// attempt) calls this again — a fresh process, a fresh port bind, a fresh browser tab.
    func startLinearInstall() {
        linearInstallPhase = .installing(adminStatement: "")
        linearInstallTask = Task { [weak self] in
            await self?.runLinearInstall()
        }
    }

    /// Closing the Setup window, or the Operator's own Cancel while awaiting the browser, terminates the
    /// child process — setup is not an Act, so nothing here survives past this session.
    func cancelLinearInstall() {
        linearInstallTask?.cancel()
        engine.terminate()
        linearInstallPhase = .failed(text: "Cancelled.")
    }

    private func runLinearInstall() async {
        let credential = configExists || linearCredential == Self.defaultLinearCredential ? nil : linearCredential
        let arguments = SetupInvocation.installLinearArguments(linearCredential: credential)
        do {
            let status = try await engine.run(arguments: arguments) { [weak self] line in
                self?.handleLinearInstallLine(line)
            }
            if status != 0, !linearInstallPhase.isInstalled, !isTerminalLinearInstallPhase {
                linearInstallPhase = .failed(text: "yh exited \(status).")
            }
        } catch {
            linearInstallPhase = .failed(text: "\(error)")
        }
    }

    private var isTerminalLinearInstallPhase: Bool {
        switch linearInstallPhase {
        case .portsBusy, .failed: true
        default: false
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
            linearInstallPhase = .installing(adminStatement: text)
        case .browserOpened:
            break // The admin statement already carries everything worth showing at this point.
        case .awaitingApproval:
            if case .installing(let text) = linearInstallPhase {
                linearInstallPhase = .awaitingApproval(adminStatement: text)
            } else {
                linearInstallPhase = .awaitingApproval(adminStatement: "")
            }
        case .portsBusy(let ports, let text):
            linearInstallPhase = .portsBusy(text: text, ports: ports)
        case .failed(_, let text):
            linearInstallPhase = .failed(text: text)
        case .installed(let workspaceName):
            linearInstallPhase = .installed(workspaceName: workspaceName)
        }
    }
}
