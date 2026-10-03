import Domain
import Foundation
import LinearAdapter

/// One attempt of the remote-approval install (roadmap P17.9; spec: board-projection/
/// authorize-linear-via-remote-approval, ADR-006): setup asks the Code Relay for a session, an admin on
/// any browser approves it, and the Mac exchanges the delivered code directly with Linear using its own
/// PKCE verifier. Mirrors `LinearInstallFlow`: every side effect is injected, nothing is stored, nothing
/// is decided about workspace mismatch — that is the caller's job, once this is wired in (slice 2b).
public struct LinearRemoteInstallFlow: Sendable {
    public enum Outcome: Sendable, Equatable {
        case installed(tokens: LinearInstallFlow.InstalledTokens, identity: LinearInstallFlow.InstalledIdentity)
        /// The admin declined in Linear (the relay's `status: "rejected"`).
        case rejected(error: String)
        /// The session ended (relay `status: "expired"`, a 404, or the deadline passed with no
        /// transient error outstanding) before the admin approved.
        case expired
        /// The relay could not be reached — at `createSession`, or still unreachable when the polling
        /// deadline passed.
        case relayUnreachable(detail: String)
        /// The relay refused `createSession` as rate-limited.
        case relayRateLimited
        /// The code was delivered, but the token exchange or the confirm call failed. The relay already
        /// deleted the code on delivery, so this is not retryable: the caller must start a fresh session.
        case notCompleted(linearError: String)
    }

    public enum Event: Sendable, Equatable {
        case approvalLinkIssued(URL, expiresIn: Duration)
        case awaitingApproval
    }

    /// The relay answered outside its documented shape — `CodeRelayClient.RelayError.badResponse`,
    /// carried across as its own error rather than folded into `Outcome`, since it is a contract
    /// violation, not a state the flow's own state machine models.
    public enum FlowError: Error, Sendable, Equatable {
        case relayContract(status: Int, body: String)
    }

    private let relay: CodeRelayClient
    private let transport: LinearInstallFlow.TransportSend
    private let clock: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    private let pollInterval: Duration
    private let deadlineGrace: Duration
    private let events: @Sendable (Event) -> Void

    public init(
        relay: CodeRelayClient,
        transport: @escaping LinearInstallFlow.TransportSend,
        clock: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        pollInterval: Duration = .seconds(4),
        deadlineGrace: Duration = .seconds(5),
        events: @escaping @Sendable (Event) -> Void = { _ in }
    ) {
        self.relay = relay
        self.transport = transport
        self.clock = clock
        self.sleep = sleep
        self.pollInterval = pollInterval
        self.deadlineGrace = deadlineGrace
        self.events = events
    }

    public func run() async throws -> Outcome {
        // The verifier lives only in this local: never sent to the relay, never placed in an event or
        // an error (spec: "Code interception" edge case, ADR-006).
        let verifier = LinearAppInstallation.makeVerifier()
        let challenge = LinearAppInstallation.challenge(for: verifier)

        let session: CodeRelayClient.Session
        do {
            session = try await relay.createSession(clientID: LinearAppInstallation.clientID, codeChallenge: challenge)
        } catch .unreachable(let detail) {
            return .relayUnreachable(detail: detail)
        } catch .rateLimited {
            return .relayRateLimited
        } catch .badResponse(let status, let body) {
            throw FlowError.relayContract(status: status, body: body)
        }

        events(.approvalLinkIssued(session.approvalURL, expiresIn: session.expiresIn))
        events(.awaitingApproval)

        let code = try await poll(sessionID: session.sessionID, expiresIn: session.expiresIn)
        switch code {
        case .code(let code):
            return try await exchange(code: code, verifier: verifier)
        case .outcome(let outcome):
            return outcome
        }
    }

    /// `poll`'s own result: either the delivered code, or a terminal `Outcome` reached without ever
    /// getting one.
    private enum PollResult {
        case code(String)
        case outcome(Outcome)
    }

    private func poll(sessionID: String, expiresIn: Duration) async throws -> PollResult {
        let deadline = clock().addingTimeInterval(expiresIn.timeInterval + deadlineGrace.timeInterval)
        var lastTransient: Outcome?

        while clock() < deadline {
            let status: CodeRelayClient.SessionStatus
            do {
                status = try await relay.status(of: sessionID)
            } catch .badResponse(let httpStatus, let body) {
                throw FlowError.relayContract(status: httpStatus, body: body)
            } catch .unreachable(let detail) {
                lastTransient = .relayUnreachable(detail: detail)
                try await sleep(pollInterval)
                continue
            } catch .rateLimited(let retryAfter) {
                lastTransient = .relayRateLimited
                try await sleep(max(pollInterval, retryAfter ?? .zero))
                continue
            }

            switch status {
            case .pending:
                lastTransient = nil
                try await sleep(pollInterval)
            case .approved(let code):
                return .code(code)
            case .rejected(let error):
                return .outcome(.rejected(error: error))
            case .expired:
                return .outcome(.expired)
            }
        }

        return .outcome(lastTransient ?? .expired)
    }

    private func exchange(code: String, verifier: String) async throws -> Outcome {
        let httpTransport = ClosureHTTPTransport(sendClosure: transport)
        do {
            let pair = try await LinearAppInstallation.exchange(
                code: code, verifier: verifier, redirectURI: LinearAppInstallation.relayRedirectURI,
                transport: httpTransport, clock: clock
            )
            let identity = try await LinearAppInstallation.confirm(tokens: pair, transport: httpTransport)
            return .installed(
                tokens: LinearInstallFlow.InstalledTokens(
                    accessToken: pair.accessToken, refreshToken: pair.refreshToken, expiresAt: pair.expiresAt
                ),
                identity: LinearInstallFlow.InstalledIdentity(
                    appUserID: identity.appUserID.rawValue, workspaceID: identity.workspaceID.rawValue,
                    workspaceName: identity.workspaceName, workspaceURLKey: identity.workspaceURLKey
                )
            )
        } catch {
            return .notCompleted(linearError: String(describing: error))
        }
    }
}

extension Duration {
    fileprivate var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
