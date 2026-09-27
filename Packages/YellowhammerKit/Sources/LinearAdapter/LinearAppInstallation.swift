import CryptoKit
import Domain
import Foundation
import Security

/// Yellowhammer's Linear App Installation (roadmap P17.3, ADR-005, board-projection/install-the-linear-app):
/// the OAuth authorization-code + PKCE flow an Operator runs once, at setup, to install Yellowhammer's
/// one public Linear app into their workspace as its own app user. No client secret ever crosses this
/// flow — PKCE substitutes for one, since the app is public (its `clientID` is not a secret).
///
/// Scopes are `read,write` only, `actor=app` — never `admin`, `app:assignable`, or `app:mentionable`
/// (Linear App Installation Ruling, item 2). The three localhost redirect ports are tried in order, in
/// case one is already bound on the Operator's machine.
public enum LinearAppInstallation {
    /// Yellowhammer's one public Linear OAuth application. Public, not a secret — safe to compile in.
    public static let clientID = "e240956753e1d09cfe73dfd03e45bbc2"

    /// The redirect ports tried in order.
    public static let redirectPorts = [44837, 44838, 44839]

    static let authorizeEndpoint = URL(string: "https://linear.app/oauth/authorize")!
    static let tokenEndpoint = URL(string: "https://api.linear.app/oauth/token")!

    /// The loopback redirect URI for one of ``redirectPorts``.
    public static func redirectURI(forPort port: Int) -> URL {
        URL(string: "http://127.0.0.1:\(port)/callback")! // glossary:ignore GL001
    }

    // MARK: - PKCE

    /// A fresh PKCE code verifier: 43 characters, base64url (no padding) of 32 random bytes — within
    /// RFC 7636's 43–128 character range.
    public static func makeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URLEncode(Data(bytes))
    }

    /// The `S256` code challenge for a verifier: base64url (no padding) of its SHA-256 digest.
    public static func challenge(for verifier: String) -> String {
        base64URLEncode(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// An opaque anti-CSRF `state` value, the same shape as a verifier.
    public static func makeState() -> String {
        makeVerifier()
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Authorization

    /// The URL the Operator's browser opens to authorize the installation.
    public static func authorizationURL(redirectURI: URL, challenge: String, state: String) -> URL {
        var components = URLComponents(url: authorizeEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "read,write"),
            URLQueryItem(name: "actor", value: "app"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "prompt", value: "consent")
        ]
        return components.url!
    }

    // MARK: - Token exchange

    /// Exchanges the authorization code for the installation's first token pair. No `client_secret` —
    /// the verifier is PKCE's substitute for one.
    public static func exchange(
        code: String, verifier: String, redirectURI: URL, transport: any HTTPTransport,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) async throws(BoardError) -> LinearTokenPair {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(formBody([
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", redirectURI.absoluteString),
            ("client_id", clientID),
            ("code_verifier", verifier)
        ]).utf8)

        let failure = LinearFailure(secrets: [])
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch {
            throw failure.transport(error)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw failure.installationTokenRefused(data, response)
        }
        return try decodeTokenPair(data, clock: clock, failure: failure)
    }

    /// Confirms the installation once tokens are in hand: the app user's own id and the workspace it
    /// installed into.
    public static func confirm(
        tokens: LinearTokenPair, transport: any HTTPTransport
    ) async throws(BoardError) -> LinearInstallationIdentity {
        let query = "query YellowhammerInstallationConfirm { viewer { id name } organization { id name } }"
        let request: URLRequest
        do {
            request = try LinearGraphQL.request(query: query, variables: [:], token: tokens.accessToken)
        } catch {
            throw .refused("the request to Linear could not be encoded")
        }
        let failure = LinearFailure(secrets: [tokens.accessToken, tokens.refreshToken])
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch {
            throw failure.transport(error)
        }
        if let refusal = failure.status(data, response) ?? failure.graphQL(data, response) {
            throw refusal
        }
        let envelope: LinearGraphQLEnvelope<LinearInstallationConfirmPayload>
        do {
            envelope = try LinearGraphQL.decoder().decode(
                LinearGraphQLEnvelope<LinearInstallationConfirmPayload>.self, from: data
            )
        } catch {
            throw failure.unreadable(error)
        }
        guard let payload = envelope.data else {
            throw .unreadableResponse("Linear's response carried neither data nor errors")
        }
        return LinearInstallationIdentity(
            appUserID: BoardObjectID(rawValue: payload.viewer.id),
            workspaceID: BoardObjectID(rawValue: payload.organization.id),
            workspaceName: payload.organization.name
        )
    }

    /// Shared with ``LinearInstallationTokenSource``'s refresh: both decode the same grant shape.
    static func decodeTokenPair(
        _ data: Data, clock: @Sendable () -> Date, failure: LinearFailure
    ) throws(BoardError) -> LinearTokenPair {
        let grant: LinearOAuthGrant
        do {
            grant = try JSONDecoder().decode(LinearOAuthGrant.self, from: data)
        } catch {
            throw failure.unreadable(error)
        }
        guard !grant.accessToken.isEmpty, !grant.refreshToken.isEmpty else {
            throw .notAuthenticated("Linear issued an empty token")
        }
        return LinearTokenPair(
            accessToken: grant.accessToken, refreshToken: grant.refreshToken,
            expiresAt: clock().addingTimeInterval(grant.expiresIn)
        )
    }

    /// Shared with ``LinearInstallationTokenSource``'s refresh request body.
    static func formBody(_ pairs: [(String, String)]) -> String {
        pairs.map { "\($0)=\(formEncode($1))" }.joined(separator: "&")
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

/// The token endpoint's grant shape, shared by the authorization-code exchange and the refresh grant —
/// both return a (rotated) refresh token alongside the access token (Linear App Installation Ruling).
struct LinearOAuthGrant: Decodable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Double

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

struct LinearInstallationConfirmPayload: Decodable {
    let viewer: LinearInstallationViewer
    let organization: LinearInstallationOrganization
}

struct LinearInstallationViewer: Decodable {
    let id: String
}

struct LinearInstallationOrganization: Decodable {
    let id: String
    let name: String
}

/// The installed app user's identity and the workspace it belongs to — opaque strings only; no Linear
/// type crosses the Board Port (ADR-001).
public struct LinearInstallationIdentity: Sendable, Equatable {
    public let appUserID: BoardObjectID
    public let workspaceID: BoardObjectID
    public let workspaceName: String

    public init(appUserID: BoardObjectID, workspaceID: BoardObjectID, workspaceName: String) {
        self.appUserID = appUserID
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
    }
}

/// One installation's access and refresh tokens (ADR-005). Its descriptions redact both, so
/// interpolating the value into a log line cannot leak them.
public struct LinearTokenPair: Codable, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date

    public init(accessToken: String, refreshToken: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    public var description: String {
        "LinearTokenPair(accessToken: <redacted>, refreshToken: <redacted>, expiresAt: \(expiresAt))"
    }

    public var debugDescription: String { description }

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresAt = "expires_at"
    }

    /// The persisted-storage JSON shape (P17.4, ADR-005): an explicit ISO-8601 `expires_at`, never
    /// `Date`'s ambiguous default encoding, since this JSON may be read back by a different build than
    /// the one that wrote it.
    public func encoded() throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        guard let json = String(data: data, encoding: .utf8) else {
            throw LinearTokenPairCodingError.couldNotEncode
        }
        return json
    }

    /// The inverse of ``encoded()``.
    public init(storedJSON: String) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self = try decoder.decode(Self.self, from: Data(storedJSON.utf8))
    }
}

public enum LinearTokenPairCodingError: Error, Sendable {
    case couldNotEncode
}
