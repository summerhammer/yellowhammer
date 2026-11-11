import Domain
import Foundation
import OrcaADEAdapter
import Testing

@Suite("Orca Probe observations")
struct OrcaProbeTests {
    private let worktree = WorkspaceWorktree(
        id: .init(rawValue: "own"), path: "/probe", branch: "probe", displayName: "probe"
    )

    private func output(_ result: String) -> OrcaCommandOutput {
        .init(exitCode: 0, stdout: "{\"ok\":true,\"result\":\(result)}", stderr: "")
    }

    @Test("Only the Probe's own CLI, Worktree and prompt can establish recognition")
    func scopedRecognition() async {
        let runner = StubOrcaCommandRunner(outputs: [output("""
            {"worktrees":[
              {"worktreeId":"other","path":"/other","agents":[
                {"agentType":"codex","conversationName":"expected","prompt":"nonce"}]},
              {"worktreeId":"own","path":"/probe","agents":[
                {"agentType":"claude","conversationName":"expected","prompt":"nonce"},
                {"agentType":"codex","conversationName":"expected","prompt":"different prompt"}]}],
             "truncated":false}
            """)])
        let result = await OrcaADEAdapter(runner: runner).probeTab(
            cli: "codex", worktree: worktree, name: "expected", nonce: "nonce"
        )
        #expect(result.tabRecognition.finding == .failed)
        #expect(result.hookTraffic.finding == .notRun)
    }

    @Test("Antigravity's vendor identifier and conversation name are checked")
    func antigravityRecognition() async {
        let runner = StubOrcaCommandRunner(outputs: [output("""
            {"worktrees":[{"worktreeId":"own","path":"/probe","agents":[
              {"agentType":"antigravity","conversationName":"expected","prompt":"nonce"}]}]}
            """)])
        let result = await OrcaADEAdapter(runner: runner).probeTab(
            cli: "agy", worktree: worktree, name: "expected", nonce: "nonce"
        )
        #expect(result.tabRecognition.finding == .passed)
    }

    @Test("A partial agents page cannot establish absence")
    func partialAgentsPage() async {
        let runner = StubOrcaCommandRunner(outputs: [output("{\"worktrees\":[],\"truncated\":true}")])
        let result = await OrcaADEAdapter(runner: runner).probeTab(
            cli: "claude", worktree: worktree, name: "expected", nonce: "nonce"
        )
        #expect(result.tabRecognition.finding == .notRun)
    }

    @Test("Hook evidence requires the Probe prompt, tool input and an installed loopback transport")
    func hookEvidence() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let hooks = home.appendingPathComponent(".orca/agent-hooks")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        try "curl http://127.0.0.1:${ORCA_AGENT_HOOK_PORT}/hook/claude".write(
            to: hooks.appendingPathComponent("claude-hook.sh"), atomically: true, encoding: .utf8
        )
        let runner = StubOrcaCommandRunner(outputs: [output("""
            {"worktrees":[{"worktreeId":"own","path":"/probe","agents":[
              {"agentType":"claude","conversationName":"expected","prompt":"nonce",
               "toolInput":"sh yh-probe-hold.sh tabclose"}]}]}
            """)])
        let result = await OrcaADEAdapter(runner: runner).probeTab(
            cli: "claude", worktree: worktree, name: "expected", nonce: "nonce", homeDirectory: home
        )
        #expect(result.hookTraffic.finding == .passed)
        #expect(result.hookTraffic.detail?.contains("no packet capture") == true)
    }

    @Test("Disabled search is unconfirmed and does not say History is absent")
    func disabledSearch() async {
        let runner = StubOrcaCommandRunner(outputs: [output("{\"kind\":\"unavailable\",\"reason\":\"disabled\"}")])
        let result = await OrcaADEAdapter(runner: runner).probeHistory(
            cli: "codex", cwd: "/probe", sessionID: "session", name: "expected", nonce: "nonce"
        )
        #expect(result.sessionHistory.finding == .notRun)
        #expect(result.sessionHistory.detail?.contains("panel was not observed") == true)
        #expect(result.sessionName.finding == .notRun)
    }

    @Test("History pagination matches session id, agent, cwd and actual title")
    func historyPagination() async {
        let runner = StubOrcaCommandRunner(outputs: [output("""
            {"kind":"results","hits":[{"agent":"codex","cwd":"/other","sessionId":"session",
             "title":"expected","source":{"presence":"present"}}],"page":{"cursor":"next","hasMore":true}}
            """), output("""
            {"kind":"results","hits":[{"agent":"codex","cwd":"/probe","sessionId":"session",
             "title":"first prompt","source":{"presence":"present"}}],"page":{"cursor":null,"hasMore":false}}
            """)])
        let result = await OrcaADEAdapter(runner: runner).probeHistory(
            cli: "codex", cwd: "/probe", sessionID: "session", name: "expected", nonce: "nonce"
        )
        #expect(result.sessionHistory.finding == .passed)
        #expect(result.sessionName.finding == .failed)
        #expect(runner.calls.count == 2)
        #expect(runner.calls.last?.suffix(2) == ["--cursor", "next"])
        #expect(runner.calls.first?.contains("/probe") == true)
    }

    @Test("History accepts a physical cwd behind the Probe's temporary-directory symlink")
    func historyCwdAlias() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("real")
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        let physical = real.resolvingSymlinksInPath().path
        let runner = StubOrcaCommandRunner(outputs: [output("""
            {"kind":"results","hits":[{"agent":"claude","cwd":"\(physical)","sessionId":"session",
             "title":"expected","source":{"presence":"present"}}],"page":{"cursor":null,"hasMore":false}}
            """)])
        let result = await OrcaADEAdapter(runner: runner).probeHistory(
            cli: "claude", cwd: alias.path, sessionID: "session", name: "expected", nonce: "nonce"
        )
        #expect(result.sessionHistory.finding == .passed)
        #expect(result.sessionName.finding == .passed)
        #expect(runner.calls.first?.filter { $0 == "--path" }.count == 2)
    }
}
