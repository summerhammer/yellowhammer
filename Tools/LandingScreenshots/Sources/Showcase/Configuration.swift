import Foundation

// The configuration files both showcase directories hold. Routes are written in the three-part
// `cli/model/effort` shorthand, with models the shipped tests and docs already use as routes; the shipped
// model discovery reads the installed CLI's own list at run time, so there is no static catalogue to quote.

private let machineConfiguration = """
    [board.linear.connections.orbit]
    credential = "keychain:linear"
    workspace = "workspace-1"
    yellowhammer_identity = "app-user-1"

    [code_hosting.github.connections.github]
    type = "keychain"
    credential = "keychain:github"

    [cli.claude]

    [cli.codex]

    [cli.agy]

    [[routing]]
    route = "claude/opus/high"
    fallbacks = ["claude/sonnet/medium"]

    [[routing]]
    repo_role = "backend"
    route = "claude/sonnet/medium"
    fallbacks = ["codex/gpt-5.4/high"]

    [[routing]]
    repo_role = "web"
    route = "codex/gpt-5.4/high"
    fallbacks = ["claude/sonnet/high"]

    [[routing]]
    repo_role = "mobile"
    route = "agy/gemini-3-pro/high"
    fallbacks = ["claude/opus/high"]
    """

private let orbitProject = """
    id = "orbit"
    name = "Orbit"
    spec_source = "~/dev/orbit/orbit-spec"

    [code_hosting]
    connection = "github"

    [board.linear]
    connection = "orbit"
    project = "ORB"

    [[repos]]
    name = "orbit-api"
    path = "~/dev/orbit/orbit-api"
    role = "backend"
    check = "swift test"

    [[repos]]
    name = "orbit-web"
    path = "~/dev/orbit/orbit-web"
    role = "web"
    check = "pnpm test"

    [[repos]]
    name = "orbit-ios"
    path = "~/dev/orbit/orbit-ios"
    role = "mobile"
    check = "make test"

    [schedule]
    night_start = "22:00"
    night_end = "06:00"
    build_every_minutes = 15
    """

private let harborProject = """
    id = "harbor"
    name = "Harbor"
    spec_source = "~/dev/harbor/harbor-spec"

    [code_hosting]
    connection = "github"

    [board.linear]
    connection = "orbit"
    project = "HBR"

    [[repos]]
    name = "harbor-api"
    path = "~/dev/harbor/harbor-api"
    role = "backend"
    check = "swift test"

    [[repos]]
    name = "harbor-app"
    path = "~/dev/harbor/harbor-app"
    role = "mobile"
    check = "make test"
    """

/// `config.toml` and `projects/orbit.toml`, `projects/harbor.toml` in `directory`.
func writeConfigurationFiles(into directory: URL) throws {
    let projects = directory.appending(component: "projects", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    try machineConfiguration.write(
        to: directory.appending(component: "config.toml"), atomically: true, encoding: .utf8
    )
    try orbitProject.write(to: projects.appending(component: "orbit.toml"), atomically: true, encoding: .utf8)
    try harborProject.write(to: projects.appending(component: "harbor.toml"), atomically: true, encoding: .utf8)
}
