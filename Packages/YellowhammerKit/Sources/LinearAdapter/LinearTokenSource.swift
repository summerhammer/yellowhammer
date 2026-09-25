import Domain
import Foundation

/// Obtains and caches the client-credentials access token of the registered Linear OAuth application —
/// an application-actor token, never an Operator's personal API key.
///
/// The token is refreshed `skew` before its stated expiry, so a call never starts with a token about to
/// lapse. Neither the token nor the secret is ever logged.
actor LinearTokenSource {
    static let endpoint = URL(string: "https://api.linear.app/oauth/token")!
    /// `scope` is required by the grant; omitting it fails `invalid_scope`.
    static let scope = "read,write"

    static let retryDelay: Duration = .milliseconds(250)

    private let credentials: LinearCredentials
    private let transport: any HTTPTransport
    private let clock: @Sendable () -> Date
    private let skew: TimeInterval
    private let sleep: @Sendable (Duration) async throws -> Void
    private var cached: (token: String, refreshAt: Date)?

    init(
        credentials: LinearCredentials,
        transport: any HTTPTransport,
        clock: @escaping @Sendable () -> Date,
        skew: TimeInterval = 60,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.credentials = credentials
        self.transport = transport
        self.clock = clock
        self.skew = skew
        self.sleep = sleep
    }

    /// The cached token while it is fresh; otherwise a new one.
    func token() async throws(BoardError) -> String {
        if let cached, clock() < cached.refreshAt {
            return cached.token
        }
        let (token, refreshAt) = try await requestToken()
        cached = (token, refreshAt)
        return token
    }

    /// Forgets the cached token, so the next call obtains a new one.
    func invalidate() {
        cached = nil
    }

    /// The secrets a failure message must never carry.
    var secrets: [String] {
        [credentials.clientSecret] + (cached.map { [$0.token] } ?? [])
    }

    private var failure: LinearFailure {
        LinearFailure(secrets: secrets)
    }

    private func requestToken() async throws(BoardError) -> (String, Date) {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.formBody(credentials).utf8)

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch {
            throw failure.transport(error)
        }
        guard (200..<300).contains(response.statusCode) else {
            // Linear sometimes intermittently answers 400 invalid_client to valid credentials, then 200
            // on an immediate retry (issue #160). Give a single invalid_client one retry after a short delay
            // before treating it as a real credential failure.
            if failure.isInvalidClient(data) {
                try? await sleep(Self.retryDelay)
                let retryData: Data
                let retryResponse: HTTPURLResponse
                do {
                    (retryData, retryResponse) = try await transport.send(request)
                } catch {
                    throw failure.transport(error)
                }
                guard (200..<300).contains(retryResponse.statusCode) else {
                    throw failure.tokenRefused(retryData, retryResponse)
                }
                return try decodeGrant(retryData)
            }
            throw failure.tokenRefused(data, response)
        }
        return try decodeGrant(data)
    }

    private func decodeGrant(_ data: Data) throws(BoardError) -> (String, Date) {
        let grant: LinearTokenGrant
        do {
            grant = try JSONDecoder().decode(LinearTokenGrant.self, from: data)
        } catch {
            throw failure.unreadable(error)
        }
        guard !grant.accessToken.isEmpty else {
            throw .notAuthenticated("Linear issued an empty access token")
        }
        return (grant.accessToken, clock().addingTimeInterval(grant.expiresIn - skew))
    }

    static func formBody(_ credentials: LinearCredentials) -> String {
        [
            ("grant_type", "client_credentials"),
            ("client_id", credentials.clientID),
            ("client_secret", credentials.clientSecret),
            ("scope", scope)
        ]
        .map { "\($0)=\(formEncode($1))" }
        .joined(separator: "&")
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

/// The token endpoint's successful response.
private struct LinearTokenGrant: Decodable {
    let accessToken: String
    let expiresIn: Double

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
    }
}
