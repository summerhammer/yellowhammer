import Foundation
import XCTest

// The fixture configuration, split from `YellowhammerUITests.swift` to keep the class under SwiftLint's
// body-length limit.
extension OverviewWindowUITests {
    /// The fixture configuration: three Projects, one refused Project file, and no Journals. Shared
    /// with `SettingsWindowUITests`, and with `PulseJournalUITests`, which adds `archive`'s Journal.
    static func writeConfiguration(in directory: URL) throws {
        let projects = directory.appending(component: "projects", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try """
        [board.linear.connections.acme]
        credential = "keychain:linear"
        workspace = "workspace-1"
        yellowhammer_identity = "app-user-1"
        [code_hosting.github.connections.github]
        type = "keychain"
        credential = "keychain:github"

        [cli.claude]

        [[routing]]
        route = "claude/sonnet"
        """.write(to: directory.appending(component: "config.toml"), atomically: true, encoding: .utf8)
        // A refused Project: the loader rejects the malformed line, so it never reaches the sidebar.
        try """
        id = "broken"
        name = "Broken"
        [[repos
        """.write(to: projects.appending(component: "broken.toml"), atomically: true, encoding: .utf8)
        // Id order differs from name order on purpose; the sidebar lists in configured (id) order.
        for (id, name) in [("archive", "Zed Archive"), ("owner", "Owner"), ("reader", "Reader")] {
            try """
            id = "\(id)"
            name = "\(name)"
            spec_source = "~/dev/spec"

            [code_hosting]
            connection = "github"

            [board.linear]
            connection = "acme"
            project = "\(id.uppercased())"

            [[repos]]
            name = "\(id)"
            path = "~/dev/\(id)"
            role = "backend"
            check = "swift test"
            """.write(to: projects.appending(component: "\(id).toml"), atomically: true, encoding: .utf8)
        }
    }
}
