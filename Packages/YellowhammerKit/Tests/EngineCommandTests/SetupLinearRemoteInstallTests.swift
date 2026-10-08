import Config
import Domain
@testable import EngineCommand
import Foundation
import Synchronization
import Testing

// roadmap P17.9 (spec: board-projection/authorize-linear-via-remote-approval, ADR-006): the remote-
// approval install path's decision, outcome handling and NDJSON emission, with the Code Relay and
// Linear's own transport both stubbed through one routing transport — no real socket or network call.

let relayTestBaseURL = URL(string: "https://relay.test")!

/// One `eventsJSONRemoteFailureReasons` case — named fields instead of a tuple (SwiftLint's
/// `large_tuple`).
private struct RemoteFailureCase {
    let route: RelayRoute
    let reply: StubHTTPTransport.Reply
    let reason: LinearInstallEvent.FailureReason
}

/// One scripted reply, keyed by how `RelayRoutingTransport` classifies a request — the Code Relay's two
/// endpoints, plus Linear's own token/GraphQL endpoints the remote flow's exchange reaches directly.
enum RelayRoute: Hashable {
    case relaySession
    case relayStatus(String)
    case linearToken
    case linearGraphQL
}

/// Routes each request to a queue of scripted replies by host + path, since a remote-install attempt
/// interleaves relay polls with a later Linear call — a single FIFO queue can't express that sequence.
final class RelayRoutingTransport: Sendable {
    private let queues: Mutex<[RelayRoute: [StubHTTPTransport.Reply]]>
    private let captured: Mutex<[URLRequest]>

    init(_ scripts: [RelayRoute: [StubHTTPTransport.Reply]]) {
        queues = Mutex(scripts)
        captured = Mutex([])
    }

    var requests: [URLRequest] { captured.withLock { $0 } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        captured.withLock { $0.append(request) }
        let route = Self.classify(request)
        let reply = queues.withLock { queues -> StubHTTPTransport.Reply? in
            guard var replies = queues[route], !replies.isEmpty else { return nil }
            let reply = replies.removeFirst()
            queues[route] = replies
            return reply
        }
        switch reply {
        case .response(let status, let headers, let body)?:
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers
            )!
            return (body, response)
        case .failure(let code)?:
            throw URLError(code)
        case nil:
            Issue.record("unscripted request for \(route): \(request.url?.absoluteString ?? "?")")
            throw URLError(.cannotConnectToHost)
        }
    }

    private static func classify(_ request: URLRequest) -> RelayRoute {
        let url = request.url!
        if url.host == relayTestBaseURL.host {
            if url.path == "/api/session" { return .relaySession }
            return .relayStatus(url.lastPathComponent)
        }
        if url.path == "/oauth/token" { return .linearToken }
        return .linearGraphQL
    }
}

/// A manual clock plus a `sleep` that advances it instead of actually waiting, so a remote-install
/// attempt's poll never really sleeps in a test.
final class RemoteInstallClock: Sendable {
    private let now: Mutex<Date>
    init(_ start: Date = Date(timeIntervalSince1970: 0)) { now = Mutex(start) }
    func clock() -> Date { now.withLock { $0 } }
    func sleep(_ duration: Duration) async throws {
        let (seconds, attoseconds) = duration.components
        now.withLock { $0 = $0.addingTimeInterval(Double(seconds) + Double(attoseconds) / 1e18) }
    }
}

func relaySessionReply(sessionID: String = "s1", expiresIn: Int = 900) -> StubHTTPTransport.Reply {
    .response(
        status: 201, headers: ["Content-Type": "application/json"],
        body: Data(
            (
                #"{"session_id":"\#(sessionID)","#
                    + #""install_url":"https://relay.test/install/\#(sessionID)","#
                    + #""expires_in":\#(expiresIn)}"#
            ).utf8
        )
    )
}

func relayStatusReply(_ body: String, status: Int = 200) -> StubHTTPTransport.Reply {
    .response(status: status, headers: ["Content-Type": "application/json"], body: Data(body.utf8))
}

let relayPendingReply = relayStatusReply(#"{"status":"pending"}"#)
let relayApprovedReply = relayStatusReply(#"{"status":"approved","code":"the-code"}"#)

func linearTokenReply() -> StubHTTPTransport.Reply {
    .response(
        status: 200, headers: ["Content-Type": "application/json"],
        body: Data(#"{"access_token":"at-1","refresh_token":"rt-1","token_type":"Bearer","expires_in":7200}"#.utf8)
    )
}

func linearGraphQLReply(
    workspaceID: String = "workspace-1", workspaceName: String = "Acme", workspaceURLKey: String = "acme",
    appUserID: String = "app-user-1"
) -> StubHTTPTransport.Reply {
    .response(
        status: 200, headers: ["Content-Type": "application/json"],
        body: Data(
            (
                #"{"data":{"viewer":{"id":"\#(appUserID)","name":"Yellowhammer"},"#
                    + #""organization":{"id":"\#(workspaceID)","name":"\#(workspaceName)","#
                    + #""urlKey":"\#(workspaceURLKey)"}}}"#
            ).utf8
        )
    )
}

/// Remote-only seams: the portBinder/opener are never reached unless a test explicitly switches to the
/// local path, in which case pass `portBinder`/`opener` for a working loopback (see `localLoopback*`).
func remoteSeams(
    transport: RelayRoutingTransport, clock: RemoteInstallClock,
    portBinder: @escaping @Sendable (Int) throws -> any CallbackListening = { port in
        throw LoopbackCallbackServer.BindError.busy(port: port)
    },
    opener: @escaping @Sendable (URL) async throws -> Void = { _ in }
) -> LinearInstallSeams {
    LinearInstallSeams(
        portBinder: portBinder, holderLookup: NeverCalledPortHolderLookup(), opener: opener,
        transport: transport.send, relayBaseURL: relayTestBaseURL, remoteSleep: clock.sleep
    )
}

/// A working loopback `portBinder`/opener pair, echoing the flow's own `state` back — for the test that
/// switches from the remote path to the local one on `.relayUnreachable`.
private func localLoopbackSeamPair(
    opened: URLRecorder = URLRecorder()
) -> (
    portBinder: @Sendable (Int) throws -> any CallbackListening, opener: @Sendable (URL) async throws -> Void
) {
    let state = Mutex("")
    let portBinder: @Sendable (Int) throws -> any CallbackListening = { port in
        InstallListener(port: port) {
            .init(code: "code", state: state.withLock { $0 }, error: nil, errorDescription: nil)
        }
    }
    let opener: @Sendable (URL) async throws -> Void = { url in
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        state.withLock { $0 = items.first(where: { $0.name == "state" })?.value ?? "" }
        opened.record(url)
    }
    return (portBinder, opener)
}

/// A throwaway `LinearInstallationStore` bound to a fresh keychain reference and lock file, so remote-
/// install tests can assert on what was (or was not) stored without touching the machine's real ones.
func freshLinearInstallationStore() -> (store: LinearInstallationStore, reference: CredentialReference) {
    let reference = CredentialReference("keychain:test-install-\(UUID().uuidString)")!
    let lockPath = FileManager.default.temporaryDirectory
        .appending(component: "yh-test-lock-\(UUID().uuidString).lock", directoryHint: .notDirectory)
    let store = LinearInstallationStore(
        reference: reference, keychain: KeychainCredentialStore(), machineLock: MachineLock(fileURL: lockPath)
    )
    return (store, reference)
}

@Suite("Setup: the remote-approval Linear install step (P17.9)")
struct SetupLinearRemoteInstallTests {
    @Test("""
    --events json remote happy path emits adminStatement, approvalLinkIssued, awaitingRemoteApproval, \
    installed; the pair is stored, config has workspace/yellowhammer_identity
    """)
    func eventsJSONRemoteHappyPathEmitsSequence() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        let board = await makeBoard(members: [operatorMember])
        let transport = RelayRoutingTransport([
            .relaySession: [relaySessionReply()],
            .relayStatus("s1"): [relayApprovedReply],
            .linearToken: [linearTokenReply()],
            .linearGraphQL: [linearGraphQLReply()]
        ])
        let clock = RemoteInstallClock()
        let seams = remoteSeams(transport: transport, clock: clock)
        let credentials = RecordingCredentialStore.withGitHub()
        let events = Mutex<[LinearInstallEvent]>([])
        let (store, _) = freshLinearInstallationStore()
        let arguments = makeArguments(
            initialize: false, operatorID: "user-op", installLinear: true, events: "json", remote: true
        )
        let setup = try makeSetup(
            arguments: arguments, directory: directory, board: board, credentials: credentials,
            linearInstallSeams: seams, linearInstallationStore: { _ in store },
            linearInstallEvents: { event in events.withLock { $0.append(event) } }
        )

        try await setup.run()

        let recorded = events.withLock { $0 }
        guard case .adminStatement = recorded.first else {
            Issue.record("expected .adminStatement first, got \(String(describing: recorded))")
            return
        }
        guard case .approvalLinkIssued(let url, let expiresIn, _) = recorded[1] else {
            Issue.record("expected .approvalLinkIssued second, got \(String(describing: recorded[1]))")
            return
        }
        #expect(url == "https://relay.test/install/s1")
        #expect(expiresIn == 900)
        #expect(recorded[2] == .awaitingRemoteApproval)
        #expect(recorded[3] == .installed(workspaceName: "Acme", installation: "acme"))
        #expect(recorded.count == 4)

        #expect(try store.tokenStore.read() != nil)
        let machine = try MachineConfiguration.load(contentsOf: directory.url.appending(component: "config.toml"))
        #expect(machine.linearInstallations.count == 1)
        let installation = try #require(machine.linearInstallations.first)
        #expect(installation.workspace == BoardObjectID(rawValue: "workspace-1"))
        #expect(installation.appUser == BoardObjectID(rawValue: "app-user-1"))
    }

    @Test("Events-json rejected/expired/relayUnreachable/relayRateLimited each fail with the matching reason")
    func eventsJSONRemoteFailureReasons() async throws {
        let cases: [RemoteFailureCase] = [
            RemoteFailureCase(
                route: .relayStatus("s1"),
                reply: relayStatusReply(#"{"status":"rejected","error":"access_denied"}"#), reason: .rejected
            ),
            RemoteFailureCase(
                route: .relayStatus("s1"), reply: relayStatusReply("{}", status: 404), reason: .expired
            ),
            RemoteFailureCase(
                route: .relaySession, reply: .failure(.notConnectedToInternet), reason: .relayUnreachable
            ),
            RemoteFailureCase(
                route: .relaySession, reply: relayStatusReply("{}", status: 429), reason: .relayRateLimited
            )
        ]
        for testCase in cases {
            let directory = ConfigurationDirectory()
            try directory.writeMachineFile()
            let board = await makeBoard(members: [operatorMember])
            var scripts: [RelayRoute: [StubHTTPTransport.Reply]] = [.relaySession: [relaySessionReply()]]
            scripts[testCase.route] = [testCase.reply]
            let transport = RelayRoutingTransport(scripts)
            let clock = RemoteInstallClock()
            let seams = remoteSeams(transport: transport, clock: clock)
            let credentials = RecordingCredentialStore.withGitHub()
            let events = Mutex<[LinearInstallEvent]>([])
            let arguments = makeArguments(initialize: false, installLinear: true, events: "json", remote: true)
            let setup = try makeSetup(
                arguments: arguments, directory: directory, board: board, credentials: credentials,
                linearInstallSeams: seams, linearInstallEvents: { event in events.withLock { $0.append(event) } }
            )

            await #expect(throws: SetupError.self) { try await setup.run() }

            let recorded = events.withLock { $0 }
            guard case .failed(let reason, _) = recorded.last else {
                Issue.record(
                    "expected .failed last for \(testCase.reason), got \(String(describing: recorded.last))"
                )
                continue
            }
            #expect(reason == testCase.reason)
        }
    }

    @Test("Interactive: the admin question answered 'r' takes the remote path, happy path")
    func adminQuestionAnsweredRemoteHappyPath() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        let board = await makeBoard(members: [operatorMember])
        let transport = RelayRoutingTransport([
            .relaySession: [relaySessionReply()],
            .relayStatus("s1"): [relayApprovedReply],
            .linearToken: [linearTokenReply()],
            .linearGraphQL: [linearGraphQLReply()]
        ])
        let clock = RemoteInstallClock()
        let seams = remoteSeams(transport: transport, clock: clock)
        let credentials = RecordingCredentialStore.withGitHub()
        let console = ScriptedConsole(answers: ["r"])
        let (store, _) = freshLinearInstallationStore()
        let arguments = makeArguments(initialize: false, operatorID: "user-op", installation: "acme")
        let setup = try makeSetup(
            arguments: arguments, directory: directory, board: board, console: console, credentials: credentials,
            linearInstallSeams: seams, linearInstallationStore: { _ in store }
        )

        try await setup.run()

        #expect(try store.tokenStore.read() != nil)
    }

    @Test("Interactive: relayUnreachable, then 'l', runs the local loopback flow to install")
    func relayUnreachableThenLocalInstalls() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        let board = await makeBoard(members: [operatorMember])
        let transport = RelayRoutingTransport([
            .relaySession: [.failure(.notConnectedToInternet)],
            .linearToken: [linearTokenReply()],
            .linearGraphQL: [linearGraphQLReply()]
        ])
        let clock = RemoteInstallClock()
        let opened = URLRecorder()
        let loopback = localLoopbackSeamPair(opened: opened)
        let seams = remoteSeams(
            transport: transport, clock: clock, portBinder: loopback.portBinder, opener: loopback.opener
        )
        let credentials = RecordingCredentialStore.withGitHub()
        let console = ScriptedConsole(answers: ["r", "l"])
        let (store, _) = freshLinearInstallationStore()
        let arguments = makeArguments(initialize: false, operatorID: "user-op", installation: "acme")
        let setup = try makeSetup(
            arguments: arguments, directory: directory, board: board, console: console, credentials: credentials,
            linearInstallSeams: seams, linearInstallationStore: { _ in store }
        )

        try await setup.run()

        #expect(opened.urls.count == 1)
        #expect(try store.tokenStore.read() != nil)
    }

    @Test("Interactive: expired, then 'n', then approved installs with two POST /api/session calls")
    func expiredThenNewLinkInstalls() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        let board = await makeBoard(members: [operatorMember])
        let transport = RelayRoutingTransport([
            .relaySession: [relaySessionReply(sessionID: "s1"), relaySessionReply(sessionID: "s2")],
            .relayStatus("s1"): [relayStatusReply("{}", status: 404)],
            .relayStatus("s2"): [relayApprovedReply],
            .linearToken: [linearTokenReply()],
            .linearGraphQL: [linearGraphQLReply()]
        ])
        let clock = RemoteInstallClock()
        let seams = remoteSeams(transport: transport, clock: clock)
        let credentials = RecordingCredentialStore.withGitHub()
        let console = ScriptedConsole(answers: ["r", "n"])
        let (store, _) = freshLinearInstallationStore()
        let arguments = makeArguments(initialize: false, operatorID: "user-op", installation: "acme")
        let setup = try makeSetup(
            arguments: arguments, directory: directory, board: board, console: console, credentials: credentials,
            linearInstallSeams: seams, linearInstallationStore: { _ in store }
        )

        try await setup.run()

        #expect(try store.tokenStore.read() != nil)
        let sessionRequests = transport.requests.filter { $0.url?.path == "/api/session" }
        #expect(sessionRequests.count == 2)
    }

    @Test("Local notCompleted: the new copy, and 'r' switches to the remote path, which installs")
    func localNotCompletedSwitchesToRemote() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        let board = await makeBoard(members: [operatorMember])
        let transport = RelayRoutingTransport([
            .relaySession: [relaySessionReply()],
            .relayStatus("s1"): [relayApprovedReply],
            .linearToken: [linearTokenReply()],
            .linearGraphQL: [linearGraphQLReply()]
        ])
        let clock = RemoteInstallClock()
        let credentials = RecordingCredentialStore.withGitHub()
        let output = RecordingOutput()
        let console = ScriptedConsole(answers: ["i", "r"])
        let (store, _) = freshLinearInstallationStore()
        let arguments = makeArguments(initialize: false, operatorID: "user-op", installation: "acme")
        let setup = try makeSetup(
            arguments: arguments, directory: directory, board: board, console: console, credentials: credentials,
            output: output, linearInstallSeams: failingCallbackSeamsWithRelay(
                transport: transport, clock: clock
            ),
            linearInstallationStore: { _ in store }
        )

        try await setup.run()

        #expect(output.lines.contains { $0.contains(LinearInstallCopy.nonAdmin) })
        #expect(try store.tokenStore.read() != nil)
    }
}

/// `failingCallbackSeams`, but with the remote seams (relay base URL/sleep) added over the same shared
/// transport, so a local `.notCompleted` failure can switch to the remote path within one test.
private func failingCallbackSeamsWithRelay(
    transport: RelayRoutingTransport, clock: RemoteInstallClock
) -> LinearInstallSeams {
    let state = Mutex("")
    return LinearInstallSeams(
        portBinder: { port in
            InstallListener(port: port) {
                .init(code: nil, state: state.withLock { $0 }, error: "server_error", errorDescription: "broke")
            }
        },
        holderLookup: NeverCalledPortHolderLookup(),
        opener: { url in
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            state.withLock { $0 = items.first(where: { $0.name == "state" })?.value ?? "" }
        },
        transport: transport.send, relayBaseURL: relayTestBaseURL, remoteSleep: clock.sleep
    )
}
