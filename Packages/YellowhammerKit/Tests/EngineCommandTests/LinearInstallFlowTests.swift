import Domain
@testable import EngineCommand
import Foundation
import Synchronization
import Testing

// roadmap P17.6 slice (a) (spec: board-projection/install-the-linear-app, ADR-005): one attempt of the
// browser install, every side effect injected — port binder, opener, token transport — so this is
// testable end to end with stubs, never a real socket, browser or network call.

/// A `CallbackListening` stub: answers a scripted callback with no real socket. `callback` is a closure
/// rather than a fixed value so the happy-path test can echo back whatever `state` the flow generated.
private final class FakeListener: CallbackListening, Sendable {
    let port: Int
    let redirectURI: URL
    private let callback: @Sendable () -> LoopbackCallbackServer.CallbackResult
    private let closedFlag = Mutex(false)

    init(port: Int, callback: @escaping @Sendable () -> LoopbackCallbackServer.CallbackResult) {
        self.port = port
        redirectURI = LinearInstallPortsConfiguration.redirectURI(forPort: port)
        self.callback = callback
    }

    var wasClosed: Bool { closedFlag.withLock { $0 } }

    func waitForCallback(timeout: Duration) async throws -> LoopbackCallbackServer.CallbackResult {
        callback()
    }

    func close() { closedFlag.withLock { $0 = true } }
}

/// Records every URL the flow asked it to open.
private final class FakeOpener: Sendable {
    private let opened = Mutex<[URL]>([])

    var openedURLs: [URL] { opened.withLock { $0 } }

    func opener() -> @Sendable (URL) async throws -> Void {
        { url in self.opened.withLock { $0.append(url) } }
    }
}

private struct NoHolders: PortHolderLookup {
    func holder(port: Int) async -> PortHolder? { nil }
}

private typealias CallbackResult = LoopbackCallbackServer.CallbackResult

/// A fixed `CallbackResult`, wrapped as a closure for `FakeListener`.
private func fixed(_ result: CallbackResult) -> @Sendable () -> CallbackResult {
    { result }
}

@Suite("LinearInstallFlow (P17.6)")
struct LinearInstallFlowTests {
    @Test("All ports busy: the opener is never called, PortsBusy is returned")
    func allPortsBusyNeverOpensBrowser() async throws {
        let opener = FakeOpener()
        let flow = LinearInstallFlow(
            portBinder: { port in throw LoopbackCallbackServer.BindError.busy(port: port) },
            holderLookup: NoHolders(),
            opener: opener.opener(),
            transport: StubHTTPTransport([]).send
        )

        let outcome = try await flow.run()
        guard case .portsBusy(let busy) = outcome else {
            Issue.record("expected portsBusy, got \(outcome)")
            return
        }
        #expect(busy.map { $0.port } == LinearInstallPortsConfiguration.ports)
        #expect(opener.openedURLs.isEmpty)
    }

    @Test("Happy path: the opener is called once with a matching redirect_uri, then .installed")
    func happyPathInstalls() async throws {
        let opener = FakeOpener()
        let transport = StubHTTPTransport([
            InstallFlowFixture.installationGrant(accessToken: "at-1", refreshToken: "rt-1"),
            InstallFlowFixture.json(#"{"data":{"viewer":{"id":"app-user-1","name":"Yellowhammer"},"#
                + #""organization":{"id":"workspace-1","name":"Acme","urlKey":"acme"}}}"#)
        ])
        let state = Mutex("")
        let flow = LinearInstallFlow(
            portBinder: { port in
                FakeListener(port: port) {
                    .init(code: "auth-code", state: state.withLock { $0 }, error: nil, errorDescription: nil)
                }
            },
            holderLookup: NoHolders(),
            opener: { url in
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                state.withLock { $0 = items.first(where: { $0.name == "state" })?.value ?? "" }
                try await opener.opener()(url)
            },
            transport: transport.send
        )

        let outcome = try await flow.run()
        guard case .installed(let tokens, let identity) = outcome else {
            Issue.record("expected installed, got \(outcome)")
            return
        }
        #expect(tokens.accessToken == "at-1")
        #expect(identity.workspaceName == "Acme")
        #expect(identity.workspaceURLKey == "acme")
        #expect(opener.openedURLs.count == 1)
        let items = URLComponents(url: opener.openedURLs[0], resolvingAgainstBaseURL: false)?.queryItems ?? []
        let redirectItem = items.first(where: { $0.name == "redirect_uri" })?.value
        let expectedURI = LinearInstallPortsConfiguration.redirectURI(forPort: LinearInstallPortsConfiguration.ports[0])
        #expect(redirectItem == expectedURI.absoluteString)
    }

    @Test("Events are reported in order: port bound, browser opening, awaiting callback")
    func eventsReportInOrder() async throws {
        let opener = FakeOpener()
        let transport = StubHTTPTransport([
            InstallFlowFixture.installationGrant(accessToken: "at-1", refreshToken: "rt-1"),
            InstallFlowFixture.json(#"{"data":{"viewer":{"id":"app-user-1","name":"Yellowhammer"},"#
                + #""organization":{"id":"workspace-1","name":"Acme","urlKey":"acme"}}}"#)
        ])
        let state = Mutex("")
        let events = Mutex<[LinearInstallFlow.Event]>([])
        let flow = LinearInstallFlow(
            portBinder: { port in
                FakeListener(port: port) {
                    .init(code: "auth-code", state: state.withLock { $0 }, error: nil, errorDescription: nil)
                }
            },
            holderLookup: NoHolders(),
            opener: { url in
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                state.withLock { $0 = items.first(where: { $0.name == "state" })?.value ?? "" }
                try await opener.opener()(url)
            },
            transport: transport.send,
            events: { event in events.withLock { $0.append(event) } }
        )

        _ = try await flow.run()

        let recorded = events.withLock { $0 }
        #expect(recorded.count == 3)
        #expect(recorded[0] == .portBound(LinearInstallPortsConfiguration.ports[0]))
        guard case .browserOpening = recorded[1] else {
            Issue.record("expected .browserOpening, got \(recorded[1])")
            return
        }
        #expect(recorded[2] == .awaitingCallback)
    }

    @Test("A state mismatch is a failure, not an installed outcome")
    func stateMismatchFails() async throws {
        let opener = FakeOpener()
        let callback = CallbackResult(code: "code", state: "wrong", error: nil, errorDescription: nil)
        let flow = LinearInstallFlow(
            portBinder: { port in FakeListener(port: port, callback: fixed(callback)) },
            holderLookup: NoHolders(), opener: opener.opener(), transport: StubHTTPTransport([]).send
        )
        await #expect(throws: LinearInstallFlow.FlowError.stateMismatch) {
            _ = try await flow.run()
        }
    }

    /// A flow whose `FakeListener` echoes back whatever `state` the flow generated — every error-path
    /// test needs this too, since `state` is checked before `error` is dispatched on (P17.6 follow-up).
    private static func stateEchoingFlow(
        error: String?, errorDescription: String?, opener: FakeOpener,
        transport: StubHTTPTransport = StubHTTPTransport([])
    ) -> LinearInstallFlow {
        let state = Mutex("")
        return LinearInstallFlow(
            portBinder: { port in
                FakeListener(port: port) {
                    CallbackResult(
                        code: nil, state: state.withLock { $0 }, error: error, errorDescription: errorDescription
                    )
                }
            },
            holderLookup: NoHolders(),
            opener: { url in
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                state.withLock { $0 = items.first(where: { $0.name == "state" })?.value ?? "" }
                try await opener.opener()(url)
            },
            transport: transport.send
        )
    }

    @Test("access_denied is .cancelled")
    func accessDeniedIsCancelled() async throws {
        let flow = Self.stateEchoingFlow(error: "access_denied", errorDescription: nil, opener: FakeOpener())
        let outcome = try await flow.run()
        #expect(outcome == .cancelled)
    }

    @Test("A forged access_denied with the wrong state is a state-mismatch failure, not .cancelled")
    func forgedAccessDeniedIsStateMismatch() async throws {
        let opener = FakeOpener()
        let flow = LinearInstallFlow(
            portBinder: { port in
                FakeListener(port: port, callback: fixed(
                    CallbackResult(code: nil, state: "wrong", error: "access_denied", errorDescription: nil)
                ))
            },
            holderLookup: NoHolders(), opener: opener.opener(), transport: StubHTTPTransport([]).send
        )
        await #expect(throws: LinearInstallFlow.FlowError.stateMismatch) {
            _ = try await flow.run()
        }
    }

    @Test("Any other Linear error is .notCompleted, carrying Linear's text")
    func otherErrorIsNotCompleted() async throws {
        let flow = Self.stateEchoingFlow(
            error: "server_error", errorDescription: "something went wrong", opener: FakeOpener()
        )
        let outcome = try await flow.run()
        #expect(outcome == .notCompleted(linearError: "something went wrong"))
    }

    @Test("An exchange refusal is a failure, not an installed outcome")
    func exchangeRefusalIsAFailure() async throws {
        let state = Mutex("")
        let flow = LinearInstallFlow(
            portBinder: { port in
                FakeListener(port: port) {
                    CallbackResult(code: "code", state: state.withLock { $0 }, error: nil, errorDescription: nil)
                }
            },
            holderLookup: NoHolders(),
            opener: { url in
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                state.withLock { $0 = items.first(where: { $0.name == "state" })?.value ?? "" }
            },
            transport: StubHTTPTransport([.response(status: 400, headers: [:], body: Data())]).send
        )
        await #expect(throws: BoardError.self) {
            _ = try await flow.run()
        }
    }
}
