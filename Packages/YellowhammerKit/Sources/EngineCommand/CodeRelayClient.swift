import Foundation

/// The Code Relay's HTTP client (roadmap P17.9; spec: board-projection/authorize-linear-via-remote-approval,
/// ADR-006). The relay is deliberately *not* a Port (ADR-001): it never sees a token, never sees the PKCE
/// `code_verifier`, and is not vendor infrastructure `LinearAdapter` needs to be insulated from — it hands
/// back only a one-time authorization code that the Mac exchanges directly with Linear. A concrete struct,
/// not a protocol.
public struct CodeRelayClient: Sendable {
    /// The relay's production host.
    public static let productionBaseURL = URL(string: "https://app.yellowhammer.dev")!

    private let baseURL: URL
    private let transport: LinearInstallFlow.TransportSend

    /// - Parameter transport: `LinearInstallFlow`'s own closure typealias, not `LinearAdapter`'s
    ///   `HTTPTransport` protocol type — `EngineCommandTests` may not import an adapter (MB2), and this
    ///   client's callers already carry the same closure for the token exchange's transport.
    public init(baseURL: URL = productionBaseURL, transport: @escaping LinearInstallFlow.TransportSend) {
        self.baseURL = baseURL
        self.transport = transport
    }

    /// A pending remote-approval session, as the relay created it.
    public struct Session: Sendable, Equatable {
        public let sessionID: String
        public let approvalURL: URL
        public let expiresIn: Duration
    }

    /// What polling `status(of:)` currently reports.
    public enum SessionStatus: Sendable, Equatable {
        case pending
        case approved(code: String)
        case rejected(error: String)
        case expired
    }

    public enum RelayError: Error, Sendable, Equatable {
        /// A `URLError` from the transport, or the relay itself answering HTTP 503.
        case unreachable(detail: String)
        /// HTTP 429; `retryAfter` is the `Retry-After` header in seconds, when present and parseable.
        case rateLimited(retryAfter: Duration?)
        /// HTTP 400, an unexpected status (a surfaced 303 included), an undecodable body, or a response
        /// that violates the wire contract (an `install_url` on the wrong host, an empty `code`, …).
        case badResponse(status: Int, body: String)
    }

    /// `POST {base}/api/session`: starts a remote-approval session for `clientID`/`codeChallenge`. Never
    /// sends a `code_verifier` — the relay is not trusted with it.
    public func createSession(clientID: String, codeChallenge: String) async throws(RelayError) -> Session {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/session"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "client_id": clientID, "code_challenge": codeChallenge, "code_challenge_method": "S256"
        ])

        let (data, response) = try await send(request)
        guard response.statusCode == 201 else {
            throw errorFor(status: response.statusCode, response: response, body: data)
        }
        guard
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let sessionID = object["session_id"] as? String, !sessionID.isEmpty,
            let installURLString = object["install_url"] as? String,
            let installURL = URL(string: installURLString),
            let expiresInSeconds = object["expires_in"] as? Int, expiresInSeconds > 0
        else {
            throw .badResponse(status: response.statusCode, body: bodyText(data))
        }
        guard
            installURL.scheme == "https",
            installURL.host == baseURL.host,
            installURL.path == "/install/\(sessionID)"
        else {
            throw .badResponse(status: response.statusCode, body: bodyText(data))
        }
        return Session(sessionID: sessionID, approvalURL: installURL, expiresIn: .seconds(expiresInSeconds))
    }

    /// `GET {base}/api/session/<sessionID>`: the current state of a session started with `createSession`.
    public func status(of sessionID: String) async throws(RelayError) -> SessionStatus {
        // `appendingPathComponent` decodes an already-percent-encoded component before re-adding it
        // (it would turn `abc%2Fdef` back into two path segments), so the URL is built from a string
        // instead, keeping the percent-encoding intact as a single path segment.
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        let encodedID = sessionID.addingPercentEncoding(withAllowedCharacters: allowed) ?? sessionID
        var request = URLRequest(url: URL(string: "api/session/\(encodedID)", relativeTo: baseURL)!)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15

        let (data, response) = try await send(request)
        if response.statusCode == 404 {
            return .expired
        }
        guard response.statusCode == 200 else {
            throw errorFor(status: response.statusCode, response: response, body: data)
        }
        guard
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let status = object["status"] as? String
        else {
            // Not `bodyText(data)`: this 200 body is undecodable or missing `status`, but it may still
            // be well-formed enough to carry a `code`, which must never land in an error description.
            throw .badResponse(status: response.statusCode, body: "200 body missing a \"status\" field")
        }
        switch status {
        case "pending":
            return .pending
        case "approved":
            guard let code = object["code"] as? String, !code.isEmpty else {
                // Never let a would-be code reach an error's body text, even if it were present but
                // otherwise judged invalid by some future stricter check.
                throw .badResponse(status: response.statusCode, body: "approved with a missing or empty code")
            }
            return .approved(code: code)
        case "rejected":
            return .rejected(error: (object["error"] as? String) ?? "access_denied")
        case "expired":
            return .expired
        default:
            // Not `bodyText(data)`: an unrecognized status is still attacker- or relay-controlled JSON
            // that could carry a `code` value, which must never land in an error description.
            throw .badResponse(status: response.statusCode, body: "unrecognized status \"\(status)\"")
        }
    }

    private func send(_ request: URLRequest) async throws(RelayError) -> (Data, HTTPURLResponse) {
        do {
            return try await transport(request)
        } catch let error as URLError {
            throw .unreachable(detail: error.localizedDescription)
        } catch {
            throw .unreachable(detail: String(describing: error))
        }
    }

    private func errorFor(status: Int, response: HTTPURLResponse, body: Data) -> RelayError {
        switch status {
        case 429:
            return .rateLimited(retryAfter: retryAfter(from: response))
        case 503:
            return .unreachable(detail: "HTTP 503")
        default:
            return .badResponse(status: status, body: bodyText(body))
        }
    }

    /// `value(forHTTPHeaderField:)` is case-insensitive per HTTP semantics, unlike a plain dictionary
    /// lookup on `allHeaderFields`.
    private func retryAfter(from response: HTTPURLResponse) -> Duration? {
        guard
            let value = response.value(forHTTPHeaderField: "Retry-After"),
            let seconds = Int(value)
        else {
            return nil
        }
        return .seconds(seconds)
    }

    private func bodyText(_ data: Data) -> String {
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.count > 500 ? String(text.prefix(500)) : text
    }
}
