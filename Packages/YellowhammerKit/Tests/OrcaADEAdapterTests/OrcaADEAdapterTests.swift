import Domain
import OrcaADEAdapter
import Testing

// graph-execution/allocate-a-worktree-per-graph-and-repo: Orca ADE (vendor) is reached through the
// Workspace Port, and its 1.4.203 JSON envelope is translated here, never decided on.

@Suite("OrcaADEAdapter")
struct OrcaADEAdapterTests {
    @Test("create sends exactly the documented arguments and parses id/path/branch")
    func createSendsExactArgumentsAndParses() async throws {
        let envelope = """
            {"id":"req-1","ok":true,"result":{"worktree":{"id":"repo-1::/abs/repo/yh-proj-feat",\
            "path":"/abs/repo/yh-proj-feat","branch":"refs/heads/yh-proj-feat","displayName":"yh-proj-feat",\
            "head":"abcdef0","isMainWorktree":false,"baseRef":"main"}},"_meta":{"durationMs":12}}
            """
        let runner = StubOrcaCommandRunner(outputs: [OrcaCommandOutput(exitCode: 0, stdout: envelope, stderr: "")])
        let adapter = OrcaADEAdapter(runner: runner)

        let worktree = try await adapter.createWorktree(
            repositoryPath: "/abs/repo", name: "yh-proj-feat", baseBranch: nil
        )

        #expect(runner.calls == [
            ["worktree", "create", "--repo", "path:/abs/repo", "--name", "yh-proj-feat", "--no-parent", "--json"]
        ])
        #expect(worktree.id == WorktreeID(rawValue: "repo-1::/abs/repo/yh-proj-feat"))
        #expect(worktree.path == "/abs/repo/yh-proj-feat")
        #expect(worktree.branch == "yh-proj-feat")
        #expect(worktree.displayName == "yh-proj-feat")
    }

    @Test("create appends --base-branch only when one is given")
    func createAppendsBaseBranchWhenGiven() async throws {
        let envelope = """
            {"id":"req-1","ok":true,"result":{"worktree":{"id":"repo-1::/abs/repo/yh-proj-feat",\
            "path":"/abs/repo/yh-proj-feat","branch":"refs/heads/yh-proj-feat","displayName":"yh-proj-feat",\
            "head":"abcdef0","isMainWorktree":false,"baseRef":"develop"}}}
            """
        let runner = StubOrcaCommandRunner(outputs: [OrcaCommandOutput(exitCode: 0, stdout: envelope, stderr: "")])
        let adapter = OrcaADEAdapter(runner: runner)

        _ = try await adapter.createWorktree(repositoryPath: "/abs/repo", name: "yh-proj-feat", baseBranch: "develop")

        #expect(runner.calls == [
            [
                "worktree", "create", "--repo", "path:/abs/repo", "--name", "yh-proj-feat", "--no-parent",
                "--base-branch", "develop", "--json"
            ]
        ])
    }

    @Test("A name collision is returned as-is: the adapter does not decide")
    func nameCollisionReturnedAsIs() async throws {
        let envelope = """
            {"id":"req-2","ok":true,"result":{"worktree":{"id":"repo-1::/abs/repo/yh-proj-feat-2",\
            "path":"/abs/repo/yh-proj-feat-2","branch":"refs/heads/yh-proj-feat-2","displayName":"yh-proj-feat",\
            "head":"111111","isMainWorktree":false,"baseRef":"main"}}}
            """
        let runner = StubOrcaCommandRunner(outputs: [OrcaCommandOutput(exitCode: 0, stdout: envelope, stderr: "")])
        let adapter = OrcaADEAdapter(runner: runner)

        let worktree = try await adapter.createWorktree(
            repositoryPath: "/abs/repo", name: "yh-proj-feat", baseBranch: nil
        )

        #expect(worktree.branch == "yh-proj-feat-2")
        #expect(worktree.path == "/abs/repo/yh-proj-feat-2")
        #expect(worktree.displayName == "yh-proj-feat")
    }

    @Test("repo_not_found maps to repositoryNotRegistered")
    func repoNotFoundMaps() async throws {
        let envelope = """
            {"id":"req-3","ok":false,"error":{"code":"repo_not_found","message":"no repository registered"},\
            "_meta":{}}
            """
        let runner = StubOrcaCommandRunner(outputs: [OrcaCommandOutput(exitCode: 1, stdout: envelope, stderr: "")])
        let adapter = OrcaADEAdapter(runner: runner)

        await #expect(throws: WorkspaceError.repositoryNotRegistered(path: "/abs/repo")) {
            _ = try await adapter.createWorktree(repositoryPath: "/abs/repo", name: "yh-proj-feat", baseBranch: nil)
        }
    }

    @Test("rm sends exactly the documented arguments")
    func removeSendsExactArguments() async throws {
        let envelope = """
            {"id":"req-4","ok":true,"result":{"removed":true},"_meta":{}}
            """
        let runner = StubOrcaCommandRunner(outputs: [OrcaCommandOutput(exitCode: 0, stdout: envelope, stderr: "")])
        let adapter = OrcaADEAdapter(runner: runner)

        try await adapter.removeWorktree(id: WorktreeID(rawValue: "repo-1::/abs/repo/yh-proj-feat"), force: true)

        #expect(runner.calls == [
            ["worktree", "rm", "--worktree", "id:repo-1::/abs/repo/yh-proj-feat", "--force", "--json"]
        ])
    }

    @Test("rm without force omits --force")
    func removeWithoutForceOmitsFlag() async throws {
        let envelope = """
            {"id":"req-4","ok":true,"result":{"removed":true}}
            """
        let runner = StubOrcaCommandRunner(outputs: [OrcaCommandOutput(exitCode: 0, stdout: envelope, stderr: "")])
        let adapter = OrcaADEAdapter(runner: runner)

        try await adapter.removeWorktree(id: WorktreeID(rawValue: "repo-1::/abs/repo/yh-proj-feat"), force: false)

        #expect(runner.calls == [
            ["worktree", "rm", "--worktree", "id:repo-1::/abs/repo/yh-proj-feat", "--json"]
        ])
    }

    @Test("selector_not_found maps to worktreeNotFound")
    func selectorNotFoundMaps() async throws {
        let envelope = """
            {"id":"req-5","ok":false,"error":{"code":"selector_not_found","message":"no such worktree"}}
            """
        let runner = StubOrcaCommandRunner(outputs: [OrcaCommandOutput(exitCode: 1, stdout: envelope, stderr: "")])
        let adapter = OrcaADEAdapter(runner: runner)
        let id = WorktreeID(rawValue: "repo-1::/abs/repo/missing")

        await #expect(throws: WorkspaceError.worktreeNotFound(id)) {
            try await adapter.removeWorktree(id: id, force: true)
        }
    }

    @Test("Other error codes map to refused, carrying the vendor code and message")
    func otherErrorCodesMapToRefused() async throws {
        let envelope = """
            {"id":"req-6","ok":false,"error":{"code":"worktree_dirty","message":"has uncommitted changes"}}
            """
        let runner = StubOrcaCommandRunner(outputs: [OrcaCommandOutput(exitCode: 1, stdout: envelope, stderr: "")])
        let adapter = OrcaADEAdapter(runner: runner)

        await #expect(throws: WorkspaceError.refused(code: "worktree_dirty", message: "has uncommitted changes")) {
            try await adapter.removeWorktree(
                id: WorktreeID(rawValue: "repo-1::/abs/repo/dirty"), force: true
            )
        }
    }

    @Test("Non-JSON stdout with a non-zero exit maps to unavailable")
    func nonJSONStdoutWithNonZeroExitIsUnavailable() async throws {
        let runner = StubOrcaCommandRunner(
            outputs: [OrcaCommandOutput(exitCode: 1, stdout: "orca: fatal error, cannot continue\n", stderr: "")]
        )
        let adapter = OrcaADEAdapter(runner: runner)

        await #expect(throws: WorkspaceError.self) {
            _ = try await adapter.createWorktree(repositoryPath: "/abs/repo", name: "yh-proj-feat", baseBranch: nil)
        }
        do {
            _ = try await adapter.createWorktree(repositoryPath: "/abs/repo", name: "yh-proj-feat", baseBranch: nil)
            Issue.record("expected a throw")
        } catch {
            guard case .unavailable = error else {
                Issue.record("expected .unavailable, got \(error)")
                return
            }
        }
    }

    @Test("An ok envelope missing the worktree result maps to malformedResponse")
    func missingWorktreeResultIsMalformed() async throws {
        let envelope = """
            {"id":"req-7","ok":true,"result":{},"_meta":{}}
            """
        let runner = StubOrcaCommandRunner(outputs: [OrcaCommandOutput(exitCode: 0, stdout: envelope, stderr: "")])
        let adapter = OrcaADEAdapter(runner: runner)

        do {
            _ = try await adapter.createWorktree(repositoryPath: "/abs/repo", name: "yh-proj-feat", baseBranch: nil)
            Issue.record("expected a throw")
        } catch {
            guard case .malformedResponse = error else {
                Issue.record("expected .malformedResponse, got \(error)")
                return
            }
        }
    }

    @Test("list filters out the main worktree")
    func listFiltersMainWorktree() async throws {
        let envelope = """
            {"id":"req-8","ok":true,"result":{"worktrees":[\
            {"id":"repo-1::/abs/repo","path":"/abs/repo","branch":"refs/heads/main","displayName":"repo",\
            "head":"aaa","isMainWorktree":true,"baseRef":null},\
            {"id":"repo-1::/abs/repo/yh-proj-feat","path":"/abs/repo/yh-proj-feat","branch":"refs/heads/yh-proj-feat",\
            "displayName":"yh-proj-feat","head":"bbb","isMainWorktree":false,"baseRef":"main"}\
            ]},"_meta":{}}
            """
        let runner = StubOrcaCommandRunner(outputs: [OrcaCommandOutput(exitCode: 0, stdout: envelope, stderr: "")])
        let adapter = OrcaADEAdapter(runner: runner)

        let worktrees = try await adapter.worktrees(repositoryPath: "/abs/repo")

        #expect(runner.calls == [["worktree", "list", "--repo", "path:/abs/repo", "--json"]])
        #expect(worktrees.count == 1)
        #expect(worktrees[0].branch == "yh-proj-feat")
    }

    @Test("createTerminal sends exact arguments and decodes handle and processId")
    func createTerminalSendsExactArgumentsAndParses() async throws {
        let envelope = """
            {"id":"req-t1","ok":true,"result":{"handle":"term_123","processId":4567},"_meta":{}}
            """
        let runner = StubOrcaCommandRunner(outputs: [OrcaCommandOutput(exitCode: 0, stdout: envelope, stderr: "")])
        let adapter = OrcaADEAdapter(runner: runner)

        let terminal = try await adapter.createTerminal(
            worktreeID: WorktreeID(rawValue: "repo-1::/abs/repo/feat"),
            title: "worker-tab",
            command: "echo running"
        )

        #expect(runner.calls == [
            [
                "terminal", "create",
                "--worktree", "id:repo-1::/abs/repo/feat",
                "--title", "worker-tab",
                "--command", "echo running",
                "--json"
            ]
        ])
        #expect(terminal.handle == TerminalHandle(rawValue: "term_123"))
        #expect(terminal.processID == 4567)
    }

    @Test("createTerminal tolerates missing processId")
    func createTerminalToleratesMissingProcessId() async throws {
        let envelope = """
            {"id":"req-t2","ok":true,"result":{"handle":"term_123"}}
            """
        let runner = StubOrcaCommandRunner(outputs: [OrcaCommandOutput(exitCode: 0, stdout: envelope, stderr: "")])
        let adapter = OrcaADEAdapter(runner: runner)

        let terminal = try await adapter.createTerminal(
            worktreeID: WorktreeID(rawValue: "repo-1::/abs/repo/feat"),
            title: "worker-tab",
            command: "echo running"
        )

        #expect(terminal.handle == TerminalHandle(rawValue: "term_123"))
        #expect(terminal.processID == nil)
    }

    @Test("createTerminal missing handle maps to malformedResponse")
    func createTerminalMissingHandleIsMalformed() async throws {
        let envelope = """
            {"id":"req-t3","ok":true,"result":{"processId":4567}}
            """
        let runner = StubOrcaCommandRunner(outputs: [OrcaCommandOutput(exitCode: 0, stdout: envelope, stderr: "")])
        let adapter = OrcaADEAdapter(runner: runner)

        do {
            _ = try await adapter.createTerminal(
                worktreeID: WorktreeID(rawValue: "repo-1::/abs/repo/feat"),
                title: "worker-tab",
                command: "echo running"
            )
            Issue.record("expected a throw")
        } catch {
            guard case .malformedResponse = error else {
                Issue.record("expected .malformedResponse, got \(error)")
                return
            }
        }
    }

    @Test("terminal show sends exact arguments and decodes orphaned and processId")
    func terminalShowSendsExactArgumentsAndParses() async throws {
        let envelope = """
            {"id":"req-t4","ok":true,"result":{"orphaned":false,"processId":4567}}
            """
        let runner = StubOrcaCommandRunner(outputs: [OrcaCommandOutput(exitCode: 0, stdout: envelope, stderr: "")])
        let adapter = OrcaADEAdapter(runner: runner)

        let state = try await adapter.terminal(TerminalHandle(rawValue: "term_123"))

        #expect(runner.calls == [["terminal", "show", "--terminal", "term_123", "--json"]])
        #expect(state.orphaned == false)
        #expect(state.processID == 4567)
    }

    @Test("terminal show decodes orphaned true and missing processId")
    func terminalShowDecodesOrphanedTrueAndMissingProcessId() async throws {
        let envelope = """
            {"id":"req-t5","ok":true,"result":{"orphaned":true}}
            """
        let runner = StubOrcaCommandRunner(outputs: [OrcaCommandOutput(exitCode: 0, stdout: envelope, stderr: "")])
        let adapter = OrcaADEAdapter(runner: runner)

        let state = try await adapter.terminal(TerminalHandle(rawValue: "term_123"))

        #expect(state.orphaned == true)
        #expect(state.processID == nil)
    }

    @Test("closeTerminal sends exact arguments with --tab")
    func closeTerminalSendsExactArguments() async throws {
        let envelope = """
            {"id":"req-t6","ok":true,"result":{"closed":true}}
            """
        let runner = StubOrcaCommandRunner(outputs: [OrcaCommandOutput(exitCode: 0, stdout: envelope, stderr: "")])
        let adapter = OrcaADEAdapter(runner: runner)

        try await adapter.closeTerminal(TerminalHandle(rawValue: "term_123"))

        #expect(runner.calls == [["terminal", "close", "--terminal", "term_123", "--tab", "--json"]])
    }

    @Test("selector_not_found on terminal show and close maps to terminalNotFound")
    func terminalSelectorNotFoundMapsToTerminalNotFound() async throws {
        let envelope = """
            {"id":"req-t7","ok":false,"error":{"code":"selector_not_found","message":"no such terminal"}}
            """
        let runner = StubOrcaCommandRunner(outputs: [
            OrcaCommandOutput(exitCode: 1, stdout: envelope, stderr: ""),
            OrcaCommandOutput(exitCode: 1, stdout: envelope, stderr: "")
        ])
        let adapter = OrcaADEAdapter(runner: runner)
        let handle = TerminalHandle(rawValue: "term_missing")

        await #expect(throws: WorkspaceError.terminalNotFound(handle)) {
            _ = try await adapter.terminal(handle)
        }
        await #expect(throws: WorkspaceError.terminalNotFound(handle)) {
            try await adapter.closeTerminal(handle)
        }
    }

    @Test("runtime_unavailable envelope maps to unavailable for worktree and terminal operations")
    func runtimeUnavailableEnvelopeMapsToUnavailable() async throws {
        let envelope = """
            {"id":"req-t8","ok":false,"error":{"code":"runtime_unavailable","message":"Orca is not running"}}
            """
        let runner = StubOrcaCommandRunner(outputs: [
            OrcaCommandOutput(exitCode: 1, stdout: envelope, stderr: ""),
            OrcaCommandOutput(exitCode: 1, stdout: envelope, stderr: "")
        ])
        let adapter = OrcaADEAdapter(runner: runner)

        await #expect(throws: WorkspaceError.unavailable("Orca is not running")) {
            _ = try await adapter.createWorktree(repositoryPath: "/abs/repo", name: "feat", baseBranch: nil)
        }
        await #expect(throws: WorkspaceError.unavailable("Orca is not running")) {
            _ = try await adapter.createTerminal(
                worktreeID: WorktreeID(rawValue: "wt-1"), title: "t", command: "c"
            )
        }
    }
}

@Suite("Orca ADE Repo registration adapter")
struct OrcaRepositoryRegistrationTests {
    @Test("list decodes registered paths and add sends documented arguments")
    func listAndAdd() async throws {
        let runner = StubOrcaCommandRunner(outputs: [
            OrcaCommandOutput(exitCode: 0, stdout: #"{"ok":true,"result":{"repos":[{"path":"/repo"}]}}"#, stderr: ""),
            OrcaCommandOutput(exitCode: 0, stdout: #"{"ok":true,"result":{"repo":{"path":"/spec"}}}"#, stderr: "")
        ])
        let adapter = OrcaADEAdapter(runner: runner)
        #expect(try await adapter.registeredRepositoryPaths() == ["/repo"])
        try await adapter.registerRepository(path: "/spec")
        #expect(runner.calls == [["repo", "list", "--json"], ["repo", "add", "--path", "/spec", "--json"]])
    }

    @Test("missing registration evidence fails closed", arguments: [true, false])
    func malformed(list: Bool) async throws {
        let runner = StubOrcaCommandRunner(outputs: [
            OrcaCommandOutput(exitCode: 0, stdout: #"{"ok":true,"result":{}}"#, stderr: "")
        ])
        let adapter = OrcaADEAdapter(runner: runner)
        await #expect(throws: WorkspaceError.self) {
            if list {
                _ = try await adapter.registeredRepositoryPaths()
            } else {
                try await adapter.registerRepository(path: "/repo")
            }
        }
    }

    @Test("registration refusal preserves Orca's code and error")
    func refusal() async throws {
        let runner = StubOrcaCommandRunner(outputs: [
            OrcaCommandOutput(
                exitCode: 1, stdout: #"{"ok":false,"error":{"code":"denied","message":"cannot register"}}"#,
                stderr: ""
            )
        ])
        await #expect(throws: WorkspaceError.refused(code: "denied", message: "cannot register")) {
            try await OrcaADEAdapter(runner: runner).registerRepository(path: "/repo")
        }
    }
}
