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

    static func workspace() -> any Workspace {
        OrcaADEAdapter()
    }
}
