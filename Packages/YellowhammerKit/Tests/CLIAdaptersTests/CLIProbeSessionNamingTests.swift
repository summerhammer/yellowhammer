@testable import CLIAdapters
import Domain
import Foundation
import Testing

/// Session naming (issue #800): the pure classification, and the names the Probe's two dispatches carry.
@Suite("CLIProbe session naming")
struct CLIProbeSessionNamingTests {
    private static let expected = CLIProbe.ExpectedSessionNames(cli: "claude")

    private func finding(
        namesSessions: Bool = true, sessionsProduced: Bool = true, titles: [String]?
    ) -> (ProbeFinding, String?) {
        CLIProbe.sessionNamingFinding(
            namesSessions: namesSessions, sessionsProduced: sessionsProduced, titles: titles,
            expected: Self.expected
        )
    }

    @Test("The Probe's dispatches are named YH, Probe, the CLI and the dispatch")
    func probeNames() {
        #expect(Self.expected.first == "YH · Probe · claude · unattended")
        #expect(Self.expected.last == "YH · Probe · claude · resumed")
    }

    @Test("An Adapter with no naming flag is reported not run, whatever else is known")
    func adapterWithoutNaming() {
        let (result, detail) = finding(namesSessions: false, titles: nil)
        #expect(result == .notRun)
        #expect(
            detail == "the claude Adapter has no session-naming flag, so Orca titles its sessions by their first prompt"
        )
    }

    @Test("No session from either dispatch is reported not run")
    func noSession() {
        let (result, detail) = finding(sessionsProduced: false, titles: nil)
        #expect(result == .notRun)
        #expect(detail?.contains("produced no session") == true)
    }

    @Test("An unreadable transcript is reported not run")
    func transcriptNotFound() {
        let (result, detail) = finding(titles: nil)
        #expect(result == .notRun)
        #expect(detail?.contains("transcript was not found") == true)
    }

    @Test("Both names recorded, resumed name last, passes with no detail")
    func passes() {
        let (result, detail) = finding(titles: [Self.expected.first, Self.expected.last])
        #expect(result == .passed)
        #expect(detail == nil)
    }

    @Test("No titles recorded fails and says none was found")
    func noTitles() {
        let (result, detail) = finding(titles: [])
        #expect(result == .failed)
        #expect(detail == "session naming: expected the last session title `YH · Probe · claude · resumed`, found none")
    }

    @Test("A last title that is not the resumed dispatch's name fails and names what was found")
    func wrongLastTitle() {
        let (result, detail) = finding(titles: [Self.expected.first])
        #expect(result == .failed)
        #expect(detail?.contains("found `YH · Probe · claude · unattended`") == true)
    }

    @Test("A missing first title fails even when the last is right")
    func missingFirstTitle() {
        let (result, _) = finding(titles: ["other", Self.expected.last])
        #expect(result == .failed)
    }

    @Test("ProbeDispatchContext.dispatch sets the session name, and defaults to none")
    func contextSetsSessionName() {
        let context = ProbeDispatchContext(
            route: Route(cli: "stub", model: "m", effort: "low")!, executable: "/bin/sh", environment: [:],
            worktree: URL(filePath: "/tmp/w"), runsDirectory: URL(filePath: "/tmp/r"), protectedDirectories: []
        )
        let named = context.dispatch(
            pass: .architect, family: .unattendedProbe, instruction: "x", runDirectory: URL(filePath: "/tmp/r/a"),
            timeout: .seconds(1), resume: nil, sessionName: "YH · Probe · stub · unattended"
        )
        let unnamed = context.dispatch(
            pass: .architect, family: .unattendedProbe, instruction: "x", runDirectory: URL(filePath: "/tmp/r/a"),
            timeout: .seconds(1), resume: nil
        )
        #expect(named.sessionName == "YH · Probe · stub · unattended")
        #expect(unnamed.sessionName == nil)
    }

    @Test("Codex and Antigravity do not name sessions and have no titles to read")
    func otherAdaptersDoNotName() {
        let session = CLISession(rawValue: "s")
        let dispatch = CLIDispatch(
            route: Route(cli: "codex", model: "m", effort: "low")!, pass: .worker, instruction: "x",
            worktreePath: "/tmp/w", runDirectory: URL(filePath: "/tmp/r"), timeout: .seconds(1),
            executable: "/bin/sh"
        )
        #expect(!CodexAdapter().namesSessions)
        #expect(CodexAdapter().sessionTitles(of: session, dispatch: dispatch) == nil)
        #expect(!AntigravityAdapter().namesSessions)
        #expect(AntigravityAdapter().sessionTitles(of: session, dispatch: dispatch) == nil)
        #expect(ClaudeCodeAdapter().namesSessions)
    }
}
