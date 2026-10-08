import Foundation

// The Board connections list's fixtures, split from `LinearSettingsUITests.swift` to keep it under
// SwiftLint's file-length limit.
extension LinearSettingsUITests {
    /// Two Board Connections; Project `alpha` uses `acme`, none uses `scratch`, whose Operator identity is
    /// not one of the stub's candidates.
    static let twoInstallationsTOML = """
    [board.linear.connections.acme]
    credential = "keychain:linear-acme"
    workspace = "workspace-1"
    yellowhammer_identity = "app-user-1"
    operator = "user-op"

    [board.linear.connections.scratch]
    credential = "keychain:linear-scratch"
    workspace = "workspace-2"
    yellowhammer_identity = "app-user-2"
    operator = "user-old"

    [code_hosting.github.connections.github]
    type = "keychain"
    credential = "keychain:github"

    [cli.claude]

    [[routing]]
    route = "claude/sonnet/medium"
    """

    static let alphaProjectTOML = """
    id = "alpha"
    name = "Alpha"
    spec_source = "~/dev/alpha-spec"

    [code_hosting]
    connection = "github"

    [board.linear]
    connection = "acme"
    project = "ALPHA"

    [[repos]]
    name = "backend"
    path = "~/dev/alpha-backend"
    role = "backend"
    check = "swift test"
    """

    /// `yh doctor --check linear --json`'s rows for the two installations: `acme` authorizes and has its
    /// workspace name; `scratch` was revoked, so Linear gave no name for it.
    static let twoInstallationsDoctorRows = """
    [{"check":"linear","installation":"acme","message":"ok","projects":["alpha"],"severity":"pass",\
    "subject":"authorization","workspace":"workspace-1","workspaceName":"Acme Corp"},\
    {"check":"linear","installation":"scratch","message":"installation scratch: revoked","projects":[],\
    "severity":"failure","subject":"authorization","workspace":"workspace-2"}]
    """
}
