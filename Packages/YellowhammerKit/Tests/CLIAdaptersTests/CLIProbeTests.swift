import Darwin
@testable import CLIAdapters
import Domain
import Foundation
import Synchronization
import Testing

/// Exercises ``CLIProbe`` end to end against stub `/bin/sh` executables standing in for a real
/// agent CLI (never a live `claude` or `codex`). Every scenario keeps timeouts short, so the whole
/// suite stays well under the wall-time budget.
@Suite("CLIProbe against stub CLIs", .serialized)
struct CLIProbeTests {
    private static let route = Route(cli: "stub", model: "some-model", effort: "low")!
    static let protectedDirectories = ["/Users/x/.config/yellowhammer", "/Users/x/Library/Keychains"]

    private func makeProbe(
        keychain: ProbeKeychain = StubProbeKeychain().keychain,
        workspace: (any Workspace)? = nil,
        wrapperExecutable: String? = nil
    ) -> CLIProbe {
        CLIProbe(
            dispatchTimeout: .seconds(10),
            holdObservationTimeout: .seconds(10),
            pollInterval: .milliseconds(50),
            gracePeriod: .milliseconds(300),
            keychain: keychain,
            protectedDirectories: Self.protectedDirectories,
            workspace: workspace,
            wrapperExecutable: wrapperExecutable
        )
    }

    private func makeWorkDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("yh-p74-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeExecutable(_ script: String, in workDirectory: URL) throws -> String {
        let url = workDirectory.appendingPathComponent("cli-\(UUID().uuidString).sh")
        try StubProbeCLI.write(script, to: url)
        return url.path
    }

    /// Polls until `pid` is dead, up to 500 ms — a just-killed pid can be a zombie briefly, during
    /// which `kill(pid, 0)` still succeeds.
    private static func awaitDead(_ pid: pid_t) async {
        for _ in 0..<25 {
            if kill(pid, 0) == -1 && errno == ESRCH { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test("A fully healthy stub CLI passes every probe target")
    func healthyStubPassesEveryTarget() async throws {
        let workDirectory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: workDirectory) }
        let executable = try makeExecutable(StubProbeCLI.healthy, in: workDirectory)

        let report = await makeProbe().run(
            adapter: StubProbeAdapter(), route: Self.route, executable: executable,
            workDirectory: workDirectory,
            runID: "test-run"
        )

        #expect(report.unattendedDispatch == .passed)
        #expect(report.resultFileOnCleanExit == .passed)
        #expect(report.sessionResumption == .passed)
        #expect(report.processContainment == .passed)
        #expect(report.stateContainment == .passed)
        #expect(report.reason == nil)
        #expect(report.cliVersion == "stub-cli 9.9.9")
        #expect(report.adapterVersion == "test")
    }

    @Test("A stub CLI that refuses every pass as not logged in fails unattended dispatch")
    func brokenStubFailsUnattended() async throws {
        let workDirectory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: workDirectory) }
        let executable = try makeExecutable(StubProbeCLI.notLoggedIn, in: workDirectory)

        let report = await makeProbe().run(
            adapter: StubProbeAdapter(), route: Self.route, executable: executable,
            workDirectory: workDirectory,
            runID: "test-run"
        )

        #expect(report.unattendedDispatch == .failed)
        #expect(report.resultFileOnCleanExit == .notRun)
        #expect(report.sessionResumption == .notRun)
        #expect(report.processContainment == .failed)
        let reason = try #require(report.reason)
        #expect(reason.contains("exited 1"))
        #expect(reason.contains("Not logged in"))
    }

    @Test("A stub CLI that hangs on a dispatch fails unattended dispatch as an interactive prompt")
    func hangingStubFailsUnattendedAsInteractive() async throws {
        let workDirectory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: workDirectory) }
        let executable = try makeExecutable(StubProbeCLI.hangs, in: workDirectory)

        let report = await CLIProbe(
            dispatchTimeout: .seconds(1), holdObservationTimeout: .seconds(2),
            pollInterval: .milliseconds(50), gracePeriod: .milliseconds(300),
            keychain: StubProbeKeychain().keychain,
            protectedDirectories: Self.protectedDirectories
        ).run(
            adapter: StubProbeAdapter(), route: Self.route, executable: executable,
            workDirectory: workDirectory,
            runID: "test-run"
        )

        #expect(report.unattendedDispatch == .failed)
        let reason = try #require(report.reason)
        #expect(reason.contains("interactive"))
    }

    @Test("A stub CLI that escapes its process group is still contained by the abort path's descendant sweep")
    func escapingStubIsContainedByDescendantSweep() async throws {
        let workDirectory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: workDirectory) }
        let executable = try makeExecutable(StubProbeCLI.escapes, in: workDirectory)

        let report = await makeProbe().run(
            adapter: StubProbeAdapter(), route: Self.route, executable: executable,
            workDirectory: workDirectory,
            runID: "test-run"
        )

        // The escaped tool subprocess is a direct child of the CLI leader (`setsid` never changes
        // `ppid`), so the abort path's descendant sweep (`AgentCLIProcess+Termination.swift`)
        // finds and signals it directly, by pid identity, even though it moved to a new process
        // group of its own. Containment now passes.
        #expect(report.processContainment == .passed)

        // No orphan survives the probe: give the detached descendants a moment to actually die
        // after the probe's own SIGKILL, then confirm none of the recorded hold pids remain.
        for variant in ["sigterm", "sigkill"] {
            let holdsFile = workDirectory
                .appendingPathComponent("worktree/.yh-probe/holds-\(variant)")
            guard let text = try? String(contentsOf: holdsFile, encoding: .utf8) else { continue }
            let pids = text.split(separator: "\n").compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
            for pid in pids {
                #expect(kill(pid, 0) == -1 && errno == ESRCH, "pid \(pid) (\(variant)) should be dead")
            }
        }
    }

    @Test("A stub CLI that daemonizes the hold script fails containment as never having been a descendant")
    func daemonizingStubFailsContainmentAsNotADescendant() async throws {
        let workDirectory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: workDirectory) }
        let executable = try makeExecutable(StubProbeCLI.daemonizes, in: workDirectory)

        let report = await makeProbe().run(
            adapter: StubProbeAdapter(), route: Self.route, executable: executable,
            workDirectory: workDirectory,
            runID: "test-run"
        )

        #expect(report.processContainment == .failed)
        let reason = try #require(report.reason)
        #expect(reason.contains("were not descendants of the CLI"))

        // The reason names the real CLI leader pid, so it is unmistakable which run this is about.
        for variant in ["sigterm", "sigkill"] {
            let leaderFile = workDirectory.appendingPathComponent("worktree/.yh-probe-leader-\(variant)")
            guard let leaderText = try? String(contentsOf: leaderFile, encoding: .utf8) else { continue }
            let leaderPID = leaderText.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(reason.contains("(pid \(leaderPID))"))
        }

        // No orphan survives the probe: a just-killed pid can be a zombie briefly (`kill(pid, 0)`
        // still succeeds on one), so poll for real death rather than asserting immediately.
        for variant in ["sigterm", "sigkill"] {
            let holdsFile = workDirectory.appendingPathComponent("worktree/.yh-probe/holds-\(variant)")
            guard let text = try? String(contentsOf: holdsFile, encoding: .utf8) else { continue }
            let pids = text.split(separator: "\n").compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
            for pid in pids {
                await Self.awaitDead(pid)
                #expect(kill(pid, 0) == -1 && errno == ESRCH, "pid \(pid) (\(variant)) should be dead")
            }
        }
    }

    @Test("A stub CLI that exits 0 without writing a result file fails only resultFileOnCleanExit")
    func cleanExitWithoutResultFileFailsOnlyResultFile() async throws {
        let workDirectory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: workDirectory) }
        let executable = try makeExecutable(StubProbeCLI.cleanExitNoResult, in: workDirectory)

        let report = await makeProbe().run(
            adapter: StubProbeAdapter(), route: Self.route, executable: executable,
            workDirectory: workDirectory,
            runID: "test-run"
        )

        #expect(report.unattendedDispatch == .passed)
        #expect(report.resultFileOnCleanExit == .failed)
    }

    @Test("Both direct-spawn and Orca tab host containment variants run and pass")
    func bothHostsVariantsRunAndPass() async throws {
        let workDirectory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: workDirectory) }
        let executable = try makeExecutable(StubProbeCLI.healthy, in: workDirectory)
        let wrapperURL = try passWrapperChildURL()

        let fakeWorkspace = FakeProbeWorkspace(tempDir: workDirectory)
        let probe = makeProbe(workspace: fakeWorkspace, wrapperExecutable: wrapperURL.path)

        let report = await probe.run(
            adapter: StubProbeAdapter(), route: Self.route, executable: executable,
            workDirectory: workDirectory,
            runID: "test-run"
        )

        #expect(report.processContainment == .passed)
        #expect(report.reason == nil)

        // Both hosts' run directories exist
        for variant in ["sigterm", "sigkill"] {
            let directDir = workDirectory.appending(components: "runs", "direct-\(variant)")
            let tabDir = workDirectory.appending(components: "runs", "tab-\(variant)")
            #expect(FileManager.default.fileExists(atPath: directDir.path))
            #expect(FileManager.default.fileExists(atPath: tabDir.path))
        }

        // Tab titles are probe session names
        #expect(fakeWorkspace.createdTerminals.count == 2)
        for call in fakeWorkspace.createdTerminals {
            #expect(call.title.hasPrefix("probe-"))
        }

        // Worktree and registration removed after passing run
        #expect(fakeWorkspace.registeredIDs.count == 1)
        #expect(fakeWorkspace.unregisteredIDs.count == 1)
        #expect(fakeWorkspace.unregisteredIDs.first == fakeWorkspace.registeredIDs.first)
        #expect(fakeWorkspace.removedWorktreeIDs.count == 1)
        #expect(fakeWorkspace.removedWorktreeIDs.first?.force == true)
    }

    @Test("A tab-host containment failure fails processContainment, naming the tab host")
    func tabHostContainmentFailureFailsProcessContainment() async throws {
        let workDirectory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        let script = makeEscapingTabStubScript()
        let executable = try makeExecutable(script, in: workDirectory)
        let wrapperURL = try passWrapperChildURL()

        let fakeWorkspace = FakeProbeWorkspace(tempDir: workDirectory)
        let probe = makeProbe(workspace: fakeWorkspace, wrapperExecutable: wrapperURL.path)

        let report = await probe.run(
            adapter: StubProbeAdapter(), route: Self.route, executable: executable,
            workDirectory: workDirectory,
            runID: "test-run"
        )

        #expect(report.processContainment == .failed)
        let reason = try #require(report.reason)
        #expect(reason.contains("Orca tab host"))
        #expect(reason.contains("sigterm"))

        // Worktree and registration removed even after a failing run
        #expect(fakeWorkspace.registeredIDs.count == 1)
        #expect(fakeWorkspace.unregisteredIDs.count == 1)
        #expect(fakeWorkspace.unregisteredIDs.first == fakeWorkspace.registeredIDs.first)
        #expect(fakeWorkspace.removedWorktreeIDs.count == 1)
        #expect(fakeWorkspace.removedWorktreeIDs.first?.force == true)
    }

    private func makeEscapingTabStubScript() -> String {
        StubProbeCLI.shell("""
            if [ "$1" = "--version" ]; then
                echo "stub-cli 9.9.9"
                exit 0
            fi
            instruction="$1"
            pass="$2"
            resume="$3"
            case "$pass" in
                architect)
                    if echo "$instruction" | grep -q 'yh-probe-reach.sh'; then
                        printf 'RESULT:{"schema":"yellowhammer.result.architect","version":1,'
                        printf '"outcome":"failed","reason":"keychain=blocked config=blocked linear=blocked"}\\n'
                    elif [ -n "$resume" ]; then
                        prior=$(cat .yh-probe-nonce 2>/dev/null)
                        printf 'SESSION:stub-session\\n'
                        printf 'RESULT:{"schema":"yellowhammer.result.architect","version":1,'
                        printf '"outcome":"failed","reason":"%s"}\\n' "$prior"
                    else
                        nonce=$(echo "$instruction" | grep -o 'yh-probe-[0-9a-f]\\{12\\}')
                        echo "$nonce" > .yh-probe-nonce
                        printf 'SESSION:stub-session\\n'
                        printf 'RESULT:{"schema":"yellowhammer.result.architect","version":1,'
                        printf '"outcome":"failed","reason":"%s"}\\n' "$nonce"
                    fi
                    ;;
                worker)
                    variant=$(echo "$instruction" | grep -o 'yh-probe-hold.sh [a-z]*' | awk '{print $2}')
                    if echo "$PWD" | grep -q "fake-wt"; then
                        echo $$ > .yh-probe-leader-"$variant"
                        setsid_code='POSIX::setsid(); exec { $ARGV[0] } @ARGV'
                        ( perl -MPOSIX -e "$setsid_code" /bin/sh yh-probe-hold.sh "$variant" & )
                        wait
                    else
                        sh yh-probe-hold.sh "$variant"
                        printf 'RESULT:{"schema":"yellowhammer.result.worker","version":1,'
                        printf '"outcome":"completed","commit":"0123456789abcdef0123456789abcdef01234567",'
                        printf '"summary":"stub"}\\n'
                    fi
                    ;;
            esac
            """)
    }

    @Test("With Orca unreachable, finding is direct-spawn result and reason says tab host was not exercised")
    func orcaUnreachableReportsNotExercised() async throws {
        let workDirectory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: workDirectory) }
        let executable = try makeExecutable(StubProbeCLI.healthy, in: workDirectory)

        let fakeWorkspace = FakeProbeWorkspace(tempDir: workDirectory)
        fakeWorkspace.scriptRegisterError(.unavailable("Orca daemon not running"))

        let probe = makeProbe(workspace: fakeWorkspace)

        let report = await probe.run(
            adapter: StubProbeAdapter(), route: Self.route, executable: executable,
            workDirectory: workDirectory,
            runID: "test-run"
        )

        #expect(report.processContainment == .passed)
        let reason = try #require(report.reason)
        #expect(reason.contains("Orca tab host not exercised: Orca daemon not running"))
    }

    @Test("With Orca terminal creation unreachable, reason says tab host was not exercised and containment passes")
    func orcaTerminalCreationUnreachableReportsNotExercised() async throws {
        let workDirectory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: workDirectory) }
        let executable = try makeExecutable(StubProbeCLI.healthy, in: workDirectory)
        let wrapperURL = try passWrapperChildURL()

        let fakeWorkspace = FakeProbeWorkspace(tempDir: workDirectory)
        fakeWorkspace.scriptCreateTerminalError(.unavailable("Orca terminal host unavailable"))

        let probe = makeProbe(workspace: fakeWorkspace, wrapperExecutable: wrapperURL.path)

        let report = await probe.run(
            adapter: StubProbeAdapter(), route: Self.route, executable: executable,
            workDirectory: workDirectory,
            runID: "test-run"
        )

        #expect(report.processContainment == .passed)
        let reason = try #require(report.reason)
        #expect(reason.contains("Orca tab host not exercised: Orca terminal host unavailable"))

        // Worktree and registration removed
        #expect(fakeWorkspace.unregisteredIDs.count == 1)
        #expect(fakeWorkspace.removedWorktreeIDs.count == 1)
    }
}

final class FakeProbeWorkspace: Workspace, @unchecked Sendable {
    struct TerminalCreation: Sendable {
        let worktreeID: WorktreeID
        let title: String
        let command: String
    }

    struct State {
        var scriptedRegisterError: WorkspaceError?
        var scriptedCreateWorktreeError: WorkspaceError?
        var scriptedCreateTerminalError: WorkspaceError?
        var registrations: [String] = []
        var registeredIDs: [RegistrationID] = []
        var unregisteredIDs: [RegistrationID] = []
        var worktrees: [WorktreeID: WorkspaceWorktree] = [:]
        var createdWorktrees: [WorkspaceWorktree] = []
        var removedWorktreeIDs: [(id: WorktreeID, force: Bool)] = []
        var terminals: [TerminalHandle: pid_t] = [:]
        var createdTerminals: [TerminalCreation] = []
        var closedTerminalHandles: [TerminalHandle] = []
    }

    private let state = Mutex(State())
    let tempDir: URL

    init(tempDir: URL) {
        self.tempDir = tempDir
    }

    var registeredIDs: [RegistrationID] { state.withLock { $0.registeredIDs } }
    var unregisteredIDs: [RegistrationID] { state.withLock { $0.unregisteredIDs } }
    var createdWorktrees: [WorkspaceWorktree] { state.withLock { $0.createdWorktrees } }
    var removedWorktreeIDs: [(id: WorktreeID, force: Bool)] { state.withLock { $0.removedWorktreeIDs } }
    var createdTerminals: [TerminalCreation] {
        state.withLock { $0.createdTerminals }
    }
    var closedTerminalHandles: [TerminalHandle] { state.withLock { $0.closedTerminalHandles } }

    func scriptRegisterError(_ error: WorkspaceError?) {
        state.withLock { $0.scriptedRegisterError = error }
    }

    func scriptCreateWorktreeError(_ error: WorkspaceError?) {
        state.withLock { $0.scriptedCreateWorktreeError = error }
    }

    func scriptCreateTerminalError(_ error: WorkspaceError?) {
        state.withLock { $0.scriptedCreateTerminalError = error }
    }

    func registeredRepositoryPaths() async throws(WorkspaceError) -> [String] { [] }

    func registerRepository(path: String) async throws(WorkspaceError) -> RegistrationID {
        let error = state.withLock { $0.scriptedRegisterError }
        if let error { throw error }
        let id = RegistrationID(rawValue: "reg-\(UUID().uuidString.prefix(8))")
        state.withLock {
            $0.registrations.append(path)
            $0.registeredIDs.append(id)
        }
        return id
    }

    func unregisterRepository(id: RegistrationID) async throws(WorkspaceError) {
        state.withLock {
            $0.unregisteredIDs.append(id)
        }
    }

    func createWorktree(
        repositoryPath: String, name: String, baseBranch: String?
    ) async throws(WorkspaceError) -> WorkspaceWorktree {
        let error = state.withLock { $0.scriptedCreateWorktreeError }
        if let error { throw error }
        let id = WorktreeID(rawValue: "wt-\(UUID().uuidString.prefix(8))")
        let dir = tempDir.appendingPathComponent("fake-wt-\(name)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let worktree = WorkspaceWorktree(id: id, path: dir.path, branch: name, displayName: name)
        state.withLock {
            $0.worktrees[id] = worktree
            $0.createdWorktrees.append(worktree)
        }
        return worktree
    }

    func worktrees(repositoryPath: String) async throws(WorkspaceError) -> [WorkspaceWorktree] { [] }

    func removeWorktree(id: WorktreeID, force: Bool) async throws(WorkspaceError) {
        state.withLock {
            $0.removedWorktreeIDs.append((id: id, force: force))
        }
        if let worktree = state.withLock({ $0.worktrees[id] }) {
            try? FileManager.default.removeItem(atPath: worktree.path)
        }
    }

    func createTerminal(
        worktreeID: WorktreeID, title: String, command: String
    ) async throws(WorkspaceError) -> WorkspaceTerminal {
        let error = state.withLock { $0.scriptedCreateTerminalError }
        if let error { throw error }
        let pid = try spawnCommandInFreshSession(command: command)
        let handle = TerminalHandle(rawValue: "term-\(UUID().uuidString.prefix(8))")
        state.withLock {
            $0.terminals[handle] = pid
            $0.createdTerminals.append(TerminalCreation(worktreeID: worktreeID, title: title, command: command))
        }
        return WorkspaceTerminal(handle: handle, processID: pid)
    }

    func terminal(_ handle: TerminalHandle) async throws(WorkspaceError) -> WorkspaceTerminalState {
        let pid = state.withLock { $0.terminals[handle] }
        return WorkspaceTerminalState(orphaned: false, processID: pid)
    }

    func closeTerminal(_ handle: TerminalHandle) async throws(WorkspaceError) {
        let pid = state.withLock { lockedState -> pid_t? in
            lockedState.closedTerminalHandles.append(handle)
            return lockedState.terminals[handle]
        }
        guard let pid else { return }
        kill(pid, SIGKILL)
        var status: Int32 = 0
        waitpid(pid, &status, 0)
    }

    private func spawnCommandInFreshSession(command: String) throws(WorkspaceError) -> pid_t {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }

        let flags = POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT
        posix_spawnattr_setflags(&attr, Int16(flags))

        let executable = "/bin/bash"
        let argv = [strdup(executable), strdup("-c"), strdup(command), nil]
        defer {
            for ptr in argv where ptr != nil { free(ptr) }
        }

        var pid: pid_t = 0
        let spawnResult = posix_spawn(&pid, executable, nil, &attr, argv, nil)
        guard spawnResult == 0 else {
            throw .unavailable("failed to spawn bash: \(spawnResult)")
        }
        return pid
    }
}
