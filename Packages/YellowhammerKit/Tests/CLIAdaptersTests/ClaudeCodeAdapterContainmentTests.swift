@testable import CLIAdapters
import Domain
import Foundation
import Testing

/// What the Claude adapter's `--settings` file contains per pass (issue #546).
@Suite("ClaudeCodeAdapter containment")
struct ClaudeCodeAdapterContainmentTests {
    private let adapter = ClaudeCodeAdapter()

    private static let protectedDirectories = ["/Users/x/.config/yellowhammer", "/Users/x/Library/Keychains"]
    private static let readOnlyPasses: [RunPass] = [.architect, .reviewer, .selection, .breakdown, .verifier]

    private struct LaunchedSettings {
        let args: [String]
        let json: [String: Any]
    }

    private func settings(for pass: RunPass, resume: CLISession? = nil) throws -> LaunchedSettings {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }
        let dispatch = fixture.dispatch(
            cli: "claude", pass: pass, resume: resume, protectedDirectories: Self.protectedDirectories
        )
        let args = try adapter.launch(for: dispatch).arguments
        let path = try #require(ClaudeCodeAdapterTests.value(after: "--settings", in: args))
        #expect(path == dispatch.runDirectory.appendingPathComponent("claude-settings.json").path)
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return LaunchedSettings(args: args, json: json)
    }

    @Test("The adapter version records the --settings argv", arguments: [false, true])
    func adapterVersion(_ resumed: Bool) {
        #expect(adapter.adapterVersion == "3")
    }

    @Test("Every pass, fresh and resumed, passes --settings naming the file in the run directory",
          arguments: RunPass.allCases, [false, true])
    func settingsArgument(_ pass: RunPass, _ resumed: Bool) throws {
        let resume = resumed ? CLISession(rawValue: "prior") : nil
        let result = try settings(for: pass, resume: resume)
        #expect(result.args.filter { $0 == "--settings" }.count == 1)
        let mode = pass == .worker ? "acceptEdits" : "dontAsk"
        #expect(ClaudeCodeAdapterTests.value(after: "--permission-mode", in: result.args) == mode)
    }

    @Test("A read-only pass runs in a fail-closed sandbox that denies the protected directories and vendor APIs",
          arguments: readOnlyPasses, [false, true])
    func readOnlyPassSettings(_ pass: RunPass, _ resumed: Bool) throws {
        let resume = resumed ? CLISession(rawValue: "prior") : nil
        let json = try settings(for: pass, resume: resume).json
        let sandbox = try #require(json["sandbox"] as? [String: Any])
        #expect(sandbox["enabled"] as? Bool == true)
        #expect(sandbox["failIfUnavailable"] as? Bool == true)
        #expect(sandbox["autoAllowBashIfSandboxed"] as? Bool == true)
        #expect(sandbox["allowUnsandboxedCommands"] as? Bool == false)
        let filesystem = try #require(sandbox["filesystem"] as? [String: Any])
        #expect(filesystem["denyRead"] as? [String] == Self.protectedDirectories)
        let network = try #require(sandbox["network"] as? [String: Any])
        #expect(network["strictAllowlist"] as? Bool == true)
        let denied = try #require(network["deniedDomains"] as? [String])
        for domain in ["linear.app", "*.linear.app", "github.com", "*.github.com", "api.github.com"] {
            #expect(denied.contains(domain))
        }
        #expect(denied.contains("api.linear.app") || denied.contains("*.linear.app"))
        let permissions = try #require(json["permissions"] as? [String: Any])
        let deny = try #require(permissions["deny"] as? [String])
        #expect(deny.contains("WebFetch"))
        #expect(deny.contains("WebSearch"))
        #expect(deny.contains("Read(//Users/x/.config/yellowhammer/**)"))
        #expect(deny.contains("Read(//Users/x/Library/Keychains/**)"))
    }

    @Test("The worker is not sandboxed and gets best-effort deny rules", arguments: [false, true])
    func workerSettings(_ resumed: Bool) throws {
        let resume = resumed ? CLISession(rawValue: "prior") : nil
        let json = try settings(for: .worker, resume: resume).json
        #expect(json["sandbox"] == nil)
        let permissions = try #require(json["permissions"] as? [String: Any])
        let deny = try #require(permissions["deny"] as? [String])
        for rule in [
            "Read(//Users/x/.config/yellowhammer/**)", "Read(//Users/x/Library/Keychains/**)",
            "Edit(//Users/x/.config/yellowhammer/**)", "Edit(//Users/x/Library/Keychains/**)",
            "Bash(security *)", "Bash(/usr/bin/security *)",
            "WebFetch(domain:linear.app)", "WebFetch(domain:api.linear.app)", "WebFetch(domain:api.github.com)"
        ] {
            #expect(deny.contains(rule))
        }
    }

    @Test("With no protected directories every other denial is still emitted", arguments: RunPass.allCases)
    func emptyProtectedDirectories(_ pass: RunPass) throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }
        let args = try adapter.launch(for: fixture.dispatch(cli: "claude", pass: pass)).arguments
        let path = try #require(ClaudeCodeAdapterTests.value(after: "--settings", in: args))
        let json = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any]
        )
        let deny = try #require((json["permissions"] as? [String: Any])?["deny"] as? [String])
        #expect(!deny.contains { $0.hasPrefix("Read(//") || $0.hasPrefix("Edit(//") })
        if pass == .worker {
            #expect(json["sandbox"] == nil)
            #expect(deny.contains("Bash(security *)"))
        } else {
            let sandbox = try #require(json["sandbox"] as? [String: Any])
            #expect(sandbox["enabled"] as? Bool == true)
            #expect((sandbox["filesystem"] as? [String: Any])?["denyRead"] as? [String] == [])
            #expect(deny.contains("WebFetch"))
        }
    }

    @Test("The settings file is deterministic")
    func settingsAreDeterministic() throws {
        let directories = Self.protectedDirectories
        let first = try ClaudeCodeAdapter.settingsJSON(for: .selection, protectedDirectories: directories)
        let second = try ClaudeCodeAdapter.settingsJSON(for: .selection, protectedDirectories: directories)
        #expect(first == second)
    }
}
