import Domain
import Foundation
@testable import LinearAdapter
import Testing

@Suite("Linear App Installation (P17.3, ADR-005)")
struct LinearAppInstallationTests {
    @Test("The authorization URL carries every required parameter, with the exact redirect URI")
    func authorizationURLParameters() throws {
        let redirectURI = LinearAppInstallation.redirectURI(forPort: 44837)
        let url = LinearAppInstallation.authorizationURL(
            redirectURI: redirectURI, challenge: "the-challenge", state: "the-state"
        )
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })

        #expect(url.scheme == "https")
        #expect(url.host == "linear.app")
        #expect(items["client_id"] == LinearAppInstallation.clientID)
        #expect(items["redirect_uri"] == redirectURI.absoluteString)
        #expect(items["response_type"] == "code")
        #expect(items["scope"] == "read,write")
        #expect(items["actor"] == "app")
        #expect(items["state"] == "the-state")
        #expect(items["code_challenge"] == "the-challenge")
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["prompt"] == "consent")
    }

    @Test("Redirect URIs are the three loopback ports, in order")
    func redirectPortsInOrder() {
        #expect(LinearAppInstallation.redirectPorts == [44837, 44838, 44839])
        for port in LinearAppInstallation.redirectPorts {
            let expected = "http://127.0.0.1:\(port)/callback" // glossary:ignore GL001
            #expect(LinearAppInstallation.redirectURI(forPort: port).absoluteString == expected)
        }
    }

    @Test("The relay redirect URI is the Code Relay's callback, not a loopback port")
    func relayRedirectURIIsTheRelayCallback() {
        #expect(LinearAppInstallation.relayRedirectURI.absoluteString == "https://app.yellowhammer.dev/callback")
    }

    @Test("A fresh verifier is 43–128 base64url characters")
    func verifierShape() {
        for _ in 0..<20 {
            let verifier = LinearAppInstallation.makeVerifier()
            #expect((43...128).contains(verifier.count))
            #expect(verifier.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        }
    }

    @Test("The S256 challenge matches RFC 7636 Appendix B's known vector")
    func challengeMatchesKnownVector() {
        // RFC 7636 Appendix B's verifier and its S256 challenge (the brief cited a mistyped challenge;
        // this is the value the RFC itself, and every standard PKCE implementation, actually produces).
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        #expect(LinearAppInstallation.challenge(for: verifier) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test("makeState produces an opaque value shaped like a verifier")
    func stateShape() {
        let state = LinearAppInstallation.makeState()
        #expect((43...128).contains(state.count))
    }

    @Test("exchange posts grant_type, code, redirect_uri, client_id and code_verifier — never a client_secret")
    func exchangeRequestBody() async throws {
        let transport = StubHTTPTransport([
            Fixture.installationGrant(accessToken: "access-1", refreshToken: "refresh-1", expiresIn: 3600)
        ])
        let clock = ManualClock()

        let pair = try await LinearAppInstallation.exchange(
            code: "auth-code", verifier: "the-verifier",
            redirectURI: LinearAppInstallation.redirectURI(forPort: 44837),
            transport: transport, clock: clock.read
        )

        #expect(pair.accessToken == "access-1")
        #expect(pair.refreshToken == "refresh-1")
        #expect(pair.expiresAt == clock.read().addingTimeInterval(3600))
        let request = transport.requests[0]
        let requestData = try #require(request.httpBody)
        let body = try #require(String(data: requestData, encoding: .utf8))
        #expect(body.contains("grant_type=authorization_code"))
        #expect(body.contains("code=auth-code"))
        #expect(body.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A44837%2Fcallback"))
        #expect(body.contains("client_id=\(LinearAppInstallation.clientID)"))
        #expect(body.contains("code_verifier=the-verifier"))
        #expect(!body.contains("client_secret"))
    }

    @Test("confirm decodes the app user's id and the workspace id and name")
    func confirmDecodesIdentity() async throws {
        let transport = StubHTTPTransport([
            Fixture.json(#"{"data":{"viewer":{"id":"app-user-1","name":"Yellowhammer"},"#
                + #""organization":{"id":"workspace-1","name":"Acme","urlKey":"acme"}}}"#)
        ])
        let tokens = LinearTokenPair(
            accessToken: "access-1", refreshToken: "refresh-1", expiresAt: Date(timeIntervalSince1970: 1_800_003_600)
        )

        let identity = try await LinearAppInstallation.confirm(tokens: tokens, transport: transport)

        #expect(identity.appUserID == BoardObjectID(rawValue: "app-user-1"))
        #expect(identity.workspaceID == BoardObjectID(rawValue: "workspace-1"))
        #expect(identity.workspaceName == "Acme")
        #expect(identity.workspaceURLKey == "acme")
    }

    @Test("Neither token ever appears in a description, even after a failure")
    func tokensNeverLeak() async throws {
        let pair = LinearTokenPair(
            accessToken: "leak-if-shown-access", refreshToken: "leak-if-shown-refresh",
            expiresAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        #expect(!pair.description.contains("leak-if-shown"))
        #expect(!pair.debugDescription.contains("leak-if-shown"))

        // A refused message that happens to echo the token: `.refused`'s translation must still scrub it.
        let transport = StubHTTPTransport([
            Fixture.json(#"{"errors":[{"message":"bad token leak-if-shown-access","extensions":{"code":"X"}}]}"#)
        ])
        do {
            _ = try await LinearAppInstallation.confirm(tokens: pair, transport: transport)
            Issue.record("expected a throw")
        } catch {
            #expect(!error.description.contains("leak-if-shown"))
            #expect(error.description.contains("<redacted>"))
        }
    }
}
