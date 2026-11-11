@testable import CLIAdapters
import Domain
import Foundation
import Testing

@Suite("ClaudeCodeAdapter session titles")
struct ClaudeCodeAdapterSessionTitlesTests {
    private struct Fixture {
        let tempDir = FileManager.default.temporaryDirectory
            .appending(component: "yh-session-titles-\(UUID().uuidString)", directoryHint: .isDirectory)
        var configDir: URL { tempDir.appending(component: "claude-config", directoryHint: .isDirectory) }
        var worktreeDir: URL { tempDir.appending(component: "worktree", directoryHint: .isDirectory) }

        func writeTranscript(sessionID: String, lines: [String]) throws {
            let encoded = ClaudeCodeAdapter.encodeWorktreePath(worktreeDir.path(percentEncoded: false))
            let projectDir = configDir.appending(components: "projects", encoded, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
            try Data(lines.map { $0 + "\n" }.joined().utf8).write(
                to: projectDir.appending(component: "\(sessionID).jsonl")
            )
        }

        func dispatch() -> CLIDispatch {
            CLIDispatch(
                route: Route(cli: "claude", model: "sonnet", effort: "high")!, pass: .architect, instruction: "x",
                worktreePath: worktreeDir.path(percentEncoded: false), runDirectory: tempDir, timeout: .seconds(5),
                executable: "/bin/echo", environment: ["CLAUDE_CONFIG_DIR": configDir.path(percentEncoded: false)]
            )
        }

        func cleanUp() { try? FileManager.default.removeItem(at: tempDir) }
    }

    private func title(_ name: String) -> String {
        #"{"type":"custom-title","customTitle":"\#(name)","sessionId":"s1"}"#
    }

    @Test("Titles come back in file order, a resume's title last")
    func titlesInOrder() throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        try fixture.writeTranscript(sessionID: "s1", lines: [
            title("YH · Probe · claude · unattended"),
            #"{"type":"user","uuid":"u1","message":"hi"}"#,
            "not json",
            title("YH · Probe · claude · resumed"),
            #"{"type":"assistant","uuid":"a1","message":"ok"}"#
        ])

        let titles = ClaudeCodeAdapter(configDirectory: fixture.configDir)
            .sessionTitles(of: CLISession(rawValue: "s1"), dispatch: fixture.dispatch())

        #expect(titles == ["YH · Probe · claude · unattended", "YH · Probe · claude · resumed"])
    }

    @Test("A transcript with no custom-title record has no titles")
    func noRecords() throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        try fixture.writeTranscript(sessionID: "s1", lines: [#"{"type":"user","uuid":"u1","message":"hi"}"#])

        let titles = ClaudeCodeAdapter(configDirectory: fixture.configDir)
            .sessionTitles(of: CLISession(rawValue: "s1"), dispatch: fixture.dispatch())

        #expect(titles == [])
    }

    @Test("A missing transcript cannot be read")
    func missingTranscript() throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        try FileManager.default.createDirectory(
            at: fixture.configDir.appending(component: "projects"), withIntermediateDirectories: true
        )

        let titles = ClaudeCodeAdapter(configDirectory: fixture.configDir)
            .sessionTitles(of: CLISession(rawValue: "absent"), dispatch: fixture.dispatch())

        #expect(titles == nil)
    }
}
