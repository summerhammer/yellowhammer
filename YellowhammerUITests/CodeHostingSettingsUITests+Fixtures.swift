import Foundation

// The Code Hosting pane's fixtures, split from `CodeHostingSettingsUITests.swift` to keep it under
// SwiftLint's file-length limit.
extension CodeHostingSettingsUITests {
    /// `config.toml`: a Board Connection, two Keychain token Code Hosting Connections (`github`, which Project
    /// `alpha` selects, and `company-a`) and the one Agent CLI and route the loader needs.
    static func machineTOML(includingCompanyA: Bool = true) -> String {
        var text = """
        [board.linear.connections.acme]
        credential = "keychain:linear-acme"
        workspace = "workspace-1"
        yellowhammer_identity = "app-user-1"
        operator = "user-op"

        [code_hosting.github.connections.github]
        type = "keychain"
        credential = "keychain:github"

        """
        if includingCompanyA {
            text += """

            [code_hosting.github.connections.company-a]
            type = "keychain"
            credential = "keychain:company-a"

            """
        }
        text += """

        [cli.claude]

        [[routing]]
        route = "claude/sonnet/medium"
        """
        return text
    }

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

    /// What `yh` adds to `config.toml` when it connects the gh CLI.
    static let ghConnectionTOML = """
    [code_hosting.github.connections.gh]
    type = "gh"
    """

    /// What `yh` adds to `config.toml` when it connects a Keychain token under `company-b`.
    static let companyBConnectionTOML = """
    [code_hosting.github.connections.company-b]
    type = "keychain"
    credential = "keychain:company-b"
    """

    static let companyARefusal = "The token in keychain:company-a was rejected by GitHub."

    // MARK: Report lines, as `yh config print-code-hosting-connections` prints them

    static let githubReportConnection = """
    {"name":"github","type":"keychain","identity":"octocat","state":"ok","projects":["alpha"]}
    """

    static let companyAReportConnection = """
    {"name":"company-a","type":"keychain","state":"refused","reason":"\(companyARefusal)","projects":[]}
    """

    static let ghReportConnection = """
    {"name":"gh","type":"gh","identity":"octocat","state":"ok","projects":[]}
    """

    static let companyBReportConnection = """
    {"name":"company-b","type":"keychain","identity":"octocat","state":"ok","projects":[]}
    """

    static let availableOffer = #"{"available":true,"login":"octocat"}"#

    static let unavailableOffer = """
    {"available":false,"reason":"gh is not logged in to github.com; run `gh auth login`. \
    Yellowhammer never changes gh's login."}
    """

    static func report(_ connections: [String], offer: String) -> String {
        #"{"connections":["# + connections.joined(separator: ",") + #"],"githubCLI":"# + offer + "}"
    }

    static let defaultConnections = [githubReportConnection, companyAReportConnection]
}
