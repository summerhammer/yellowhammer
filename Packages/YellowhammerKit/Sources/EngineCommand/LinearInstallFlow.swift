import Domain
import Foundation
import LinearAdapter
import Subprocess
import System

/// One attempt of the Linear App Installation's browser install (roadmap P17.6; spec: board-projection/
/// install-the-linear-app, ADR-005). Every side effect is injected — port binding, the browser opener,
/// the token exchange's transport — so this is testable end to end with stubs; nothing here is wired
/// into `Setup.run` yet (slice (a)). It stores nothing and decides nothing about workspace mismatch:
/// slice (b) does, once this is wired in.
public struct LinearInstallFlow: Sendable {
    /// The token exchange's transport, as a plain closure rather than `LinearAdapter`'s `HTTPTransport`
    /// protocol type: `EngineCommandTests` may not import an adapter (MB2), so nothing in this
    /// initializer's signature names one — only this file's own `run()` body does.
    public typealias TransportSend = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    /// What one attempt came to. Carries plain values, not `LinearAdapter`'s `LinearTokenPair`/
    /// `LinearInstallationIdentity`, for the same reason `TransportSend` is a closure: this type is
    /// part of `EngineCommand`'s own public surface, and `EngineCommandTests` must be able to name it.
    public enum Outcome: Sendable, Equatable {
        case installed(tokens: InstalledTokens, identity: InstalledIdentity)
        /// All three fixed ports were bound by another process; the browser was never opened.
        case portsBusy([(port: Int, holder: PortHolder?)])
        /// The Operator's own cancel (Linear's `error=access_denied`).
        case cancelled
        /// Any other failed install — a non-admin's attempt refused, or any other Linear-reported
        /// error — carrying Linear's own text.
        case notCompleted(linearError: String)

        public static func == (lhs: Outcome, rhs: Outcome) -> Bool {
            switch (lhs, rhs) {
            case (.installed(let lTokens, let lIdentity), .installed(let rTokens, let rIdentity)):
                lTokens == rTokens && lIdentity == rIdentity
            case (.portsBusy(let lPorts), .portsBusy(let rPorts)):
                lPorts.map(LinearInstallPortRow.init) == rPorts.map(LinearInstallPortRow.init)
            case (.cancelled, .cancelled):
                true
            case (.notCompleted(let lError), .notCompleted(let rError)):
                lError == rError
            default:
                false
            }
        }
    }

    /// The installed pair, in `LinearTokenPair`'s own shape (accessToken, refreshToken, expiresAt) but
    /// as plain values — slice (b) reconstructs a `LinearTokenPair` from this to store it.
    public struct InstalledTokens: Sendable, Equatable {
        public let accessToken: String
        public let refreshToken: String
        public let expiresAt: Date

        public init(accessToken: String, refreshToken: String, expiresAt: Date) {
            self.accessToken = accessToken
            self.refreshToken = refreshToken
            self.expiresAt = expiresAt
        }
    }

    /// The confirmed installation identity, as plain values.
    public struct InstalledIdentity: Sendable, Equatable {
        public let appUserID: String
        public let workspaceID: String
        public let workspaceName: String

        public init(appUserID: String, workspaceID: String, workspaceName: String) {
            self.appUserID = appUserID
            self.workspaceID = workspaceID
            self.workspaceName = workspaceName
        }
    }

    public enum FlowError: Error, Sendable, Equatable {
        /// The callback's `state` did not match the one this attempt sent — a forged or stale redirect.
        case stateMismatch
        /// Linear reported neither `code` nor `error` — an invariant break, not a user-facing outcome.
        case missingCode
    }

    /// What `run()` reports as it progresses, so a caller (setup's console, slice (b)) can narrate a
    /// wait of up to `callbackTimeout` instead of `run()` being silent until it returns.
    public enum Event: Sendable, Equatable {
        case portBound(Int)
        case browserOpening(URL)
        case awaitingCallback
    }

    private let portBinder: @Sendable (Int) throws -> any CallbackListening
    private let holderLookup: any PortHolderLookup
    private let opener: @Sendable (URL) async throws -> Void
    private let transport: TransportSend
    private let clock: @Sendable () -> Date
    private let callbackTimeout: Duration
    private let events: @Sendable (Event) -> Void

    public init(
        portBinder: @escaping @Sendable (Int) throws -> any CallbackListening,
        holderLookup: any PortHolderLookup,
        opener: @escaping @Sendable (URL) async throws -> Void,
        transport: @escaping TransportSend,
        clock: @escaping @Sendable () -> Date = { Date() },
        callbackTimeout: Duration = .seconds(600),
        events: @escaping @Sendable (Event) -> Void = { _ in }
    ) {
        self.portBinder = portBinder
        self.holderLookup = holderLookup
        self.opener = opener
        self.transport = transport
        self.clock = clock
        self.callbackTimeout = callbackTimeout
        self.events = events
    }

    /// The production opener: `/usr/bin/open <url>`.
    public static func systemOpener(openPath: String = "/usr/bin/open") -> @Sendable (URL) async throws -> Void {
        { url in
            try await SystemBrowserOpener.open(url, openPath: openPath)
        }
    }

    public func run() async throws -> Outcome {
        let server: any CallbackListening
        do {
            server = try await LoopbackPortSelection.select(binder: portBinder, holderLookup: holderLookup)
        } catch let busy as PortsBusyError {
            return .portsBusy(busy.ports)
        }
        defer { server.close() }
        events(.portBound(server.port))

        let verifier = LinearAppInstallation.makeVerifier()
        let challenge = LinearAppInstallation.challenge(for: verifier)
        let state = LinearAppInstallation.makeState()
        let authorizationURL = LinearAppInstallation.authorizationURL(
            redirectURI: server.redirectURI, challenge: challenge, state: state
        )

        events(.browserOpening(authorizationURL))
        try await opener(authorizationURL)
        events(.awaitingCallback)
        let callback = try await server.waitForCallback(timeout: callbackTimeout)

        // `state` is checked before dispatching on `error`: RFC 6749 §4.1.2.1 requires it on an error
        // redirect too, and a forged `error=access_denied` with the wrong (or no) `state` must not be
        // read as the Operator's own cancel.
        guard callback.state == state else {
            throw FlowError.stateMismatch
        }
        if let error = callback.error {
            if error == "access_denied" { return .cancelled }
            return .notCompleted(linearError: callback.errorDescription ?? error)
        }
        guard let code = callback.code else {
            throw FlowError.missingCode
        }

        let httpTransport = ClosureHTTPTransport(sendClosure: transport)
        let pair = try await LinearAppInstallation.exchange(
            code: code, verifier: verifier, redirectURI: server.redirectURI, transport: httpTransport, clock: clock
        )
        let identity = try await LinearAppInstallation.confirm(tokens: pair, transport: httpTransport)
        return .installed(
            tokens: InstalledTokens(
                accessToken: pair.accessToken, refreshToken: pair.refreshToken, expiresAt: pair.expiresAt
            ),
            identity: InstalledIdentity(
                appUserID: identity.appUserID.rawValue, workspaceID: identity.workspaceID.rawValue,
                workspaceName: identity.workspaceName
            )
        )
    }
}

/// Adapts a plain `TransportSend` closure to `LinearAdapter`'s `HTTPTransport` protocol — the one place
/// this file names that adapter type, since `LinearAppInstallation.exchange`/`.confirm` require it.
private struct ClosureHTTPTransport: HTTPTransport {
    let sendClosure: LinearInstallFlow.TransportSend

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await sendClosure(request)
    }
}

/// `Outcome.portsBusy`'s tuple element isn't `Equatable` on its own; wrapped so `Outcome` can compare it.
private struct LinearInstallPortRow: Equatable {
    let port: Int
    let holder: PortHolder?
    init(_ pair: (port: Int, holder: PortHolder?)) {
        port = pair.port
        holder = pair.holder
    }
}

/// Runs `/usr/bin/open <url>`, the production browser opener. `Subprocess.run`, not
/// `Process().waitUntilExit()`: the latter blocks a cooperative-pool thread for the whole run, exactly
/// what every other spawn in this module (`LSOFPortHolderLookup`, `HeadlessAppLaunch`) avoids.
enum SystemBrowserOpener {
    static func open(_ url: URL, openPath: String) async throws {
        let result = try await Subprocess.run(
            .path(FilePath(openPath)), arguments: Arguments([url.absoluteString]),
            output: .discarded, error: .discarded
        )
        guard case .exited(0) = result.terminationStatus else {
            throw SystemBrowserOpenerError.failed(status: result.terminationStatus)
        }
    }
}

enum SystemBrowserOpenerError: Error, Sendable {
    case failed(status: TerminationStatus)
}

/// The copy this flow's outcomes are rendered into (verbatim from the story), gathered in one place so
/// setup and the app's own event handling (later) use the same text.
public enum LinearInstallCopy {
    /// Shown before the browser opens (spec: "The install"). `teams` is the Operator's Projects' Linear
    /// teams (by key and name); an empty list falls back to a generic sentence rather than naming none.
    public static func beforeBrowser(teams: [BoardTeam]) -> String {
        let teamsClause = teams.isEmpty
            ? "choose the teams your Projects use"
            : "choose \(teams.map { "\($0.key) (\($0.name))" }.joined(separator: ", "))"
        return """
        Installing Yellowhammer needs a Linear workspace admin to approve it in the browser.

        On the install screen, recommended: "Only select teams…" — \(teamsClause). The preselected \
        "All public teams" also works, but then Yellowhammer must be added as a member of each team \
        (that team's Settings → Members) before setup can build the board.
        """
    }

    /// Spec: "A non-admin Operator", verbatim.
    public static let nonAdmin = """
    Installing Yellowhammer in your Linear workspace needs a workspace admin. Ask an admin to sign in \
    when the browser opens on this Mac, then approve the install. Afterwards Yellowhammer acts as its \
    own app user; the admin's account is not used again.
    """

    /// Spec: "The install", the ports-busy case (OQ94). Names each busy port and its holder.
    public static func portsBusy(_ ports: [(port: Int, holder: PortHolder?)]) -> String {
        let lines = ports.map { port, holder -> String in
            if let holder {
                "port \(port) is held by \(holder.command) (pid \(holder.pid))"
            } else {
                "port \(port) is busy"
            }
        }
        return "Yellowhammer could not install: all three loopback ports it needs are already in use — "
            + lines.joined(separator: "; ") + ". Quit one of them and retry."
    }
}
