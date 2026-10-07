import Config
import Darwin
import Foundation
import Testing

@Suite("Agent model discovery subprocesses")
struct AgentModelDiscoveryProcessTests {
    @Test("Claude keeps stdin open, uses only initialize, and runs outside the Project")
    func claudeHandshake() async throws {
        let fixture = try DiscoveryCLI("""
        assert '--safe-mode' in sys.argv and '--strict-mcp-config' in sys.argv
        assert '--no-session-persistence' in sys.argv
        assert json.loads(sys.argv[sys.argv.index('--mcp-config') + 1]) == {'mcpServers': {}}
        assert 'CLAUDECODE' not in os.environ
        assert os.stat(os.getcwd()).st_mode & 0o777 == 0o700
        assert os.stat('stdout').st_mode & 0o777 == 0o600
        request = json.loads(sys.stdin.readline())
        assert request == {'type': 'control_request', 'request_id': 'models', 'request': {'subtype': 'initialize'}}
        assert not select.select([sys.stdin], [], [], 0.1)[0], 'stdin closed or a task was sent'
        print(json.dumps({'type': 'control_response', 'response': {'subtype': 'success', 'request_id': 'models',
              'response': {'models': [{'value': 'vendor-id[1m]', 'displayName': 'Friendly name'}]}}}), flush=True)
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        time.sleep(60)
        """)
        defer { fixture.remove() }
        var environment = ProcessInfo.processInfo.environment
        environment["CLAUDECODE"] = "1"
        let start = ContinuousClock.now
        let result = await AgentModelDiscovery.discover(
            cli: "claude", executable: fixture.path, environment: environment
        )
        #expect(result == .live(models: [AgentModel(id: "vendor-id[1m]", label: "Friendly name")]))
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    @Test("Codex waits for initialize then follows every model-list page")
    func codexPagination() async throws {
        let fixture = try DiscoveryCLI("""
        assert sys.argv[1:] == ['app-server']
        request = json.loads(sys.stdin.readline())
        assert request['id'] == 1 and request['method'] == 'initialize'
        assert not select.select([sys.stdin], [], [], 0.1)[0], 'requests preceded initialize'
        print(json.dumps({'id': 1, 'result': {'userAgent': 'fixture'}}), flush=True)
        assert json.loads(sys.stdin.readline())['method'] == 'initialized'
        request = json.loads(sys.stdin.readline())
        assert request['method'] == 'model/list' and request['params']['includeHidden'] is False
        assert request['params']['cursor'] is None
        print(json.dumps({'id': request['id'], 'result': {'data': [
          {'id': 'opaque', 'model': 'exact-id', 'displayName': 'First'},
          {'model': 'secret', 'hidden': True}], 'nextCursor': 'cursor " \\n'}}), flush=True)
        request = json.loads(sys.stdin.readline())
        assert request['method'] == 'model/list' and request['params']['cursor'] == 'cursor " \\n'
        print(json.dumps({'id': request['id'], 'result': {'data': [
          {'model': 'second-id', 'displayName': 'Second'}], 'nextCursor': None}}), flush=True)
        assert not select.select([sys.stdin], [], [], 0.1)[0], 'an agent task was sent'
        time.sleep(60)
        """)
        defer { fixture.remove() }
        let result = await AgentModelDiscovery.discover(cli: "codex", executable: fixture.path)
        #expect(result == .live(models: [
            AgentModel(id: "exact-id", label: "First"), AgentModel(id: "second-id", label: "Second")
        ]))
    }

    @Test("Matching protocol errors fail promptly while the CLI remains alive", arguments: ["claude", "codex"])
    func protocolFailure(cli: String) async throws {
        let reply = cli == "claude"
            ? #"{'type': 'control_response', 'response': {'subtype': 'error', "request_id": "models","#
                + #"'error': 'upgrade required'}}"#
            : #"{'id': 1, 'error': {'code': -1, 'message': 'upgrade required'}}"#
        let fixture = try DiscoveryCLI("""
        sys.stdin.readline()
        print(json.dumps(\(reply)), flush=True)
        time.sleep(60)
        """)
        defer { fixture.remove() }
        let start = ContinuousClock.now
        let result = await AgentModelDiscovery.discover(cli: cli, executable: fixture.path)
        #expect(failure(result)?.contains("upgrade required") == true)
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    @Test("Empty protocol model lists are successful", arguments: ["claude", "codex"])
    func emptyProtocolList(cli: String) async throws {
        let script: String
        if cli == "claude" {
            script = """
            sys.stdin.readline()
            print(json.dumps({'type': 'control_response', 'response': {'subtype': 'success', 'request_id': 'models',
                  'response': {'models': []}}}), flush=True)
            """
        } else {
            script = """
            sys.stdin.readline()
            print(json.dumps({'id': 1, 'result': {}}), flush=True)
            sys.stdin.readline()
            request = json.loads(sys.stdin.readline())
            print(json.dumps({'id': request['id'], 'result': {'data': [], 'nextCursor': None}}), flush=True)
            """
        }
        let fixture = try DiscoveryCLI(script)
        defer { fixture.remove() }
        #expect(await AgentModelDiscovery.discover(cli: cli, executable: fixture.path) == .live(models: []))
    }

    @Test("Empty Antigravity lists are live, while malformed stdout fails")
    func antigravityOutput() async throws {
        for (output, expected) in [("", true), ("exact-id\\tFriendly label\\n", true), ("Please sign in\\n", false)] {
            let fixture = try DiscoveryCLI("""
            assert sys.argv[1:] == ['models']
            print('Fetching model metadata', file=sys.stderr)
            sys.stdout.write('\(output)')
            """)
            defer { fixture.remove() }
            let result = await AgentModelDiscovery.discover(cli: "agy", executable: fixture.path)
            #expect((failure(result) == nil) == expected)
            if output.isEmpty { #expect(result == .live(models: [])) }
        }
    }

    @Test("Antigravity refuses direct, symlink and PATH editor launchers before executing them")
    func refuseAntigravityEditorLauncher() async throws {
        let fixture = try DiscoveryCLI("""
        with open(os.environ['DISCOVERY_EXECUTED_MARKER'], 'w') as marker:
            marker.write('executed')
        print('exact-model\\tStandalone model')
        """)
        defer { fixture.remove() }
        let contents = fixture.directory.appendingPathComponent("Antigravity.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let launcher = contents.appendingPathComponent("agy")
        try FileManager.default.copyItem(atPath: fixture.path, toPath: launcher.path)
        let link = fixture.directory.appendingPathComponent("agy")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: launcher.path)
        let marker = fixture.directory.appendingPathComponent("executed")
        var environment = ProcessInfo.processInfo.environment
        environment["DISCOVERY_EXECUTED_MARKER"] = marker.path
        environment["PATH"] = fixture.directory.path
        for executable in [launcher.path, link.path, "agy"] {
            let result = await AgentModelDiscovery.discover(
                cli: "agy", executable: executable, environment: environment
            )
            if case .unsupported(let reason) = result {
                #expect(reason.contains("editor launcher"))
            } else { Issue.record("Expected an unsupported editor launcher, received \(result)") }
            #expect(!FileManager.default.fileExists(atPath: marker.path))
        }
        let standalone = await AgentModelDiscovery.discover(
            cli: "agy", executable: fixture.path, environment: environment
        )
        #expect(standalone == .live(models: [AgentModel(id: "exact-model", label: "Standalone model")]))
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("Stdout and stderr share a single output budget")
    func combinedOutputLimit() async throws {
        let fixture = try DiscoveryCLI("""
        sys.stdout.write('a' * 300000)
        sys.stdout.flush()
        sys.stderr.write('b' * 300000)
        sys.stderr.flush()
        time.sleep(60)
        """)
        defer { fixture.remove() }
        let result = await AgentModelDiscovery.discover(cli: "agy", executable: fixture.path)
        #expect(failure(result)?.contains("512 KiB") == true)
    }

    @Test("The entire CLI exchange has one timeout, even when SIGTERM is ignored")
    func timeout() async throws {
        let fixture = try DiscoveryCLI("""
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        time.sleep(60)
        """)
        defer { fixture.remove() }
        let start = ContinuousClock.now
        let result = await AgentModelDiscovery.discover(cli: "claude", executable: fixture.path)
        #expect(failure(result)?.contains("timed out") == true)
        #expect(ContinuousClock.now - start < .seconds(10))
    }

    @Test("Cancellation kills the CLI's process group and does not block MainActor")
    @MainActor
    func cancellationAndDescendants() async throws {
        let fixture = try DiscoveryCLI("""
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        child = subprocess.Popen(['/bin/sleep', '60'])
        with open(os.environ['DISCOVERY_CHILD_PID'], 'w') as file:
            file.write(str(child.pid))
        time.sleep(60)
        """)
        defer { fixture.remove() }
        let marker = fixture.directory.appendingPathComponent("child-pid")
        var environment = ProcessInfo.processInfo.environment
        environment["DISCOVERY_CHILD_PID"] = marker.path
        let task = Task {
            await AgentModelDiscovery.discover(cli: "claude", executable: fixture.path, environment: environment)
        }
        let deadline = ContinuousClock.now + .seconds(3)
        while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        let pid = try #require(Int32(String(contentsOf: marker, encoding: .utf8)))
        task.cancel()
        #expect(failure(await task.value)?.contains("cancelled") == true)
        let cleanupDeadline = ContinuousClock.now + .seconds(2)
        while kill(pid, 0) == 0, ContinuousClock.now < cleanupDeadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(kill(pid, 0) == -1)
    }

    private func failure(_ result: AgentModelDiscoveryResult) -> String? {
        if case .failed(let message) = result { return message }
        return nil
    }
}

private struct DiscoveryCLI {
    let directory: URL
    var path: String { directory.appendingPathComponent("cli").path }

    init(_ script: String) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("yh-discovery-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let source = "#!/usr/bin/python3\nimport json, os, select, signal, subprocess, sys, time\n" + script + "\n"
        try source.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}
