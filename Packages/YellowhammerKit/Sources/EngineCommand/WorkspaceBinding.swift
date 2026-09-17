import Domain
import OrcaADEAdapter

/// Builds the Workspace Port. The only place the Orca ADE adapter is wired (MB2).
enum WorkspaceBinding {
    static func workspace() -> any Workspace {
        OrcaADEAdapter()
    }
}
