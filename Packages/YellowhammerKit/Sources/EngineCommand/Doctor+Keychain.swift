import Config
import Domain
import Foundation

/// What a Keychain item's access list and partition list say, or why that could not be read. Never the secret.
enum KeychainAccessReport: Equatable, Sendable {
    case absent
    case unreadable(String)
    case read(KeychainItemAccess)
}

/// The seam ``Doctor`` reads a Keychain item's ACL through. The real one reads attributes only, so it never
/// raises a prompt on an item whose ACL already trusts `yh`.
protocol KeychainAccessReading: Sendable {
    func report(for reference: CredentialReference) -> KeychainAccessReport
}

struct KeychainAccessReader: KeychainAccessReading {
    private let keychain = KeychainCredentialStore()

    func report(for reference: CredentialReference) -> KeychainAccessReport {
        do {
            return .read(try keychain.access(of: reference))
        } catch {
            if error.status == errSecItemNotFound { return .absent }
            return .unreadable("\(error)")
        }
    }
}

extension Doctor {
    /// The access list and partition list of every `dev.yellowhammer` Keychain item the configuration
    /// names (Board Connection token pairs, Code Hosting Keychain tokens). One *Always Allow* on a
    /// `/usr/bin/security` prompt adds `security` to an item's access list and `apple-tool:` to its partition
    /// list, after which any process running as the Operator reads the token silently (#546). Absent items are
    /// left to the Linear and GitHub checks, which already report a missing credential.
    func runKeychainCheck(configuration: Configuration) -> [DoctorFinding] {
        var findings: [DoctorFinding] = []
        for installation in configuration.machine.linearInstallations {
            let served = configuration.projects.filter { $0.linearInstallationName == installation.name }
                .map(\.id).sorted { $0.rawValue < $1.rawValue }
            let scope = DoctorInstallationScope(
                name: installation.name, workspace: installation.workspace.rawValue, workspaceName: nil,
                projects: served
            )
            let fix = "delete the item in Keychain Access, then reconnect Board Connection "
                + "\(installation.name) with `yh setup --install-linear`"
            findings += keychainFindings(
                installation.credential, label: "Board Connection \(installation.name)", fix: fix,
                installation: scope
            )
        }
        for connection in configuration.machine.codeHostingConnections {
            guard case .keychainToken(let reference) = connection.kind else { continue }
            let served = configuration.projects.filter { $0.codeHostingConnectionName == connection.name }
                .map(\.id).sorted { $0.rawValue < $1.rawValue }
            let fix = "delete the item in Keychain Access, then replace the token in Settings › Code Hosting or "
                + "with `yh config replace-code-hosting-token \(connection.name) --token-stdin`"
            findings += keychainFindings(
                reference, label: "Code Hosting Connection \(connection.name)", fix: fix,
                codeHosting: DoctorCodeHostingScope(name: connection.name, projects: served)
            )
        }
        return findings
    }

    private func keychainFindings(
        _ reference: CredentialReference, label: String, fix: String,
        installation: DoctorInstallationScope? = nil, codeHosting: DoctorCodeHostingScope? = nil
    ) -> [DoctorFinding] {
        let item = "Keychain item \(KeychainCredentialStore.defaultService) / "
            + "\(reference.rawValue.dropFirst("keychain:".count)) (\(label))"
        func make(_ severity: DoctorSeverity, _ message: String) -> DoctorFinding {
            finding(
                .keychain, subject: reference.rawValue, severity, "\(item): \(message)",
                installation: installation, codeHosting: codeHosting
            )
        }
        switch keychainAccess.report(for: reference) {
        case .absent:
            return []
        case .unreadable(let reason):
            return [make(.warning, "its access could not be read (\(reason)); unlock the login Keychain and re-run")]
        case .read(let access):
            let reasons = access.wideningReasons
            guard !reasons.isEmpty else {
                return [make(.pass, "trusts only yh and Yellowhammer")]
            }
            return [make(
                .failure,
                "was widened: \(reasons.joined(separator: "; ")), so other processes running as you can read "
                    + "the token without a prompt; \(fix), which writes a fresh item that trusts only yh"
            )]
        }
    }
}
