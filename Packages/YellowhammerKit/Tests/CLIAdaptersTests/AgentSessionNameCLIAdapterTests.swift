@testable import CLIAdapters
import Domain
import Foundation
import Testing

@Suite("Agent CLI session name argv (AC named-session, OQ201)")
struct AgentSessionNameCLIAdapterTests {
    private let claudeAdapter = ClaudeCodeAdapter()
    private let codexAdapter = CodexAdapter()
    private let agyAdapter = AntigravityAdapter()

    // MARK: - ClaudeCodeAdapter

    @Test("ClaudeCodeAdapter carries --name on fresh launch when sessionName is set")
    func claudeFreshLaunchCarriesName() throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }
        let sessionName = "YH · test-project · YLH-1 · yellowhammer · worker · Round 1 · Attempt 1"
        let dispatch = fixture.dispatch(
            cli: "claude", model: "haiku", effort: "high", pass: .worker, sessionName: sessionName
        )

        let launch = try claudeAdapter.launch(for: dispatch)
        let args = launch.arguments

        #expect(args.contains("--session-id"))
        #expect(ClaudeCodeAdapterTests.value(after: "--name", in: args) == sessionName)
    }

    @Test("ClaudeCodeAdapter carries --name on resumed launch when sessionName is set")
    func claudeResumedLaunchCarriesName() throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }
        let session = CLISession(rawValue: "prior-session-id")
        let sessionName = "YH · test-project · YLH-1 · yellowhammer · worker · Round 2 · Attempt 1"
        let dispatch = fixture.dispatch(
            cli: "claude", model: "haiku", effort: "high", pass: .worker, resume: session, sessionName: sessionName
        )

        let launch = try claudeAdapter.launch(for: dispatch)
        let args = launch.arguments

        #expect(args.contains("--resume"))
        #expect(ClaudeCodeAdapterTests.value(after: "--resume", in: args) == "prior-session-id")
        #expect(ClaudeCodeAdapterTests.value(after: "--name", in: args) == sessionName)
    }

    @Test("ClaudeCodeAdapter omits --name on fresh and resumed launch when sessionName is nil")
    func claudeOmitsNameWhenNil() throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }

        let freshDispatch = fixture.dispatch(
            cli: "claude", model: "haiku", effort: "high", pass: .worker, sessionName: nil
        )
        let freshArgs = try claudeAdapter.launch(for: freshDispatch).arguments
        #expect(!freshArgs.contains("--name"))

        let resumeSession = CLISession(rawValue: "prior-session-id")
        let resumedDispatch = fixture.dispatch(
            cli: "claude", model: "haiku", effort: "high", pass: .worker, resume: resumeSession, sessionName: nil
        )
        let resumedArgs = try claudeAdapter.launch(for: resumedDispatch).arguments
        #expect(!resumedArgs.contains("--name"))
    }

    // MARK: - CodexAdapter

    @Test("Codex launch with sessionName set has argv identical to launch without one")
    func codexIgnoresSessionName() throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }
        let sessionName = "YH · test-project · YLH-1 · repo · worker · Round 1 · Attempt 1"

        let freshWithName = fixture.dispatch(
            cli: "codex", model: "gpt-5.5", effort: "low", pass: .worker, sessionName: sessionName
        )
        let freshWithoutName = fixture.dispatch(
            cli: "codex", model: "gpt-5.5", effort: "low", pass: .worker, sessionName: nil
        )
        let freshLaunchWithName = try codexAdapter.launch(for: freshWithName)
        let freshLaunchWithoutName = try codexAdapter.launch(for: freshWithoutName)
        #expect(freshLaunchWithName.arguments == freshLaunchWithoutName.arguments)

        let session = CLISession(rawValue: "thread-abc")
        let resumedWithName = fixture.dispatch(
            cli: "codex", model: "gpt-5.5", effort: "low", pass: .worker, resume: session, sessionName: sessionName
        )
        let resumedWithoutName = fixture.dispatch(
            cli: "codex", model: "gpt-5.5", effort: "low", pass: .worker, resume: session, sessionName: nil
        )
        let resumedLaunchWithName = try codexAdapter.launch(for: resumedWithName)
        let resumedLaunchWithoutName = try codexAdapter.launch(for: resumedWithoutName)
        #expect(resumedLaunchWithName.arguments == resumedLaunchWithoutName.arguments)
    }

    // MARK: - AntigravityAdapter

    @Test("Antigravity launch with sessionName set has argv identical to launch without one")
    func antigravityIgnoresSessionName() throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }
        let sessionName = "YH · test-project · YLH-1 · repo · worker · Round 1 · Attempt 1"

        let freshWithName = fixture.dispatch(
            cli: "agy", model: "gemini-3.8-flash-low", effort: "low", pass: .worker, sessionName: sessionName
        )
        let freshWithoutName = fixture.dispatch(
            cli: "agy", model: "gemini-3.8-flash-low", effort: "low", pass: .worker, sessionName: nil
        )
        let freshLaunchWithName = try agyAdapter.launch(for: freshWithName)
        let freshLaunchWithoutName = try agyAdapter.launch(for: freshWithoutName)
        #expect(freshLaunchWithName.arguments == freshLaunchWithoutName.arguments)

        let session = CLISession(rawValue: "conversation-xyz")
        let resumedWithName = fixture.dispatch(
            cli: "agy", model: "gemini-3.8-flash-low", effort: "low", pass: .worker,
            resume: session, sessionName: sessionName
        )
        let resumedWithoutName = fixture.dispatch(
            cli: "agy", model: "gemini-3.8-flash-low", effort: "low", pass: .worker,
            resume: session, sessionName: nil
        )
        let resumedLaunchWithName = try agyAdapter.launch(for: resumedWithName)
        let resumedLaunchWithoutName = try agyAdapter.launch(for: resumedWithoutName)
        #expect(resumedLaunchWithName.arguments == resumedLaunchWithoutName.arguments)
    }
}
