import CLIAdapters
import Domain
import Foundation
import OrcaADEAdapter

/// Builds the Workspace Port. The only place the Orca ADE adapter is wired (MB2).
enum WorkspaceBinding {
    /// Lexically normalizes a configured or vendor-reported path without reading the filesystem.
    static func repositoryPath(_ path: String, homeDirectory: URL) -> String {
        let expanded = Doctor.expandTilde(path, homeDirectory: homeDirectory.path(percentEncoded: false))
        var normalized = URL(filePath: expanded).standardizedFileURL.path(percentEncoded: false)
        while normalized.count > 1, normalized.hasSuffix("/") { normalized.removeLast() }
        return normalized
    }

    static func probeOrcaAccess() -> ProbeOrcaAccess {
        let adapter = OrcaADEAdapter()
        return ProbeOrcaAccess(
            tab: { await adapter.probeTab(cli: $0, worktree: $1, name: $2, nonce: $3) },
            history: { await adapter.probeHistory(cli: $0, cwd: $1, sessionID: $2, name: $3, nonce: $4) }
        )
    }

    static func workspace() -> any Workspace {
        OrcaADEAdapter()
    }
}
