@testable import EngineCommand
import Foundation
import Synchronization
import Testing

// roadmap P17.9 slice 1: CodeRelayClient's wire contract with the Code Relay (spec: board-projection/
// authorize-linear-via-remote-approval, ADR-006). The relay is not a Port; this is a concrete client.

/// Captures every request the client sends, alongside `StubHTTPTransport`'s scripted replies.
private final class RecordingTransport: Sendable {
    private let stub: StubHTTPTransport
    private let requests: Mutex<[URLRequest]>

    init(_ replies: [StubHTTPTransport.Reply]) {
        stub = StubHTTPTransport(replies)
        requests = Mutex([])
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.withLock { $0.append(request) }
        return try await stub.send(request)
    }

    var captured: [URLRequest] { requests.withLock { $0 } }
}

private let baseURL = URL(string: "https://app.yellowhammer.dev")!

private func json(_ body: String, status: Int, headers: [String: String] = [:]) -> StubHTTPTransport.Reply {
    var allHeaders = headers
    allHeaders["Content-Type"] = "application/json"
    return .response(status: status, headers: allHeaders, body: Data(body.utf8))
}

private func sessionBody(installURL: String, sessionID: String = "s1", expiresIn: Int = 900) -> String {
    #"{"session_id":"\#(sessionID)","install_url":"\#(installURL)","expires_in":\#(expiresIn)}"#
}

@Suite("CodeRelayClient (P17.9)")
struct CodeRelayClientTests {
    // MARK: - createSession

    @Test("createSession sends the exact method, URL, headers and three-key body")
    func createSessionSendsExactRequest() async throws {
        let transport = RecordingTransport([
            json(sessionBody(installURL: "https://app.yellowhammer.dev/install/s1"), status: 201)
        ])
        let client = CodeRelayClient(baseURL: baseURL, transport: transport.send)
        _ = try await client.createSession(clientID: "client-1", codeChallenge: "challenge-1")

        let request = try #require(transport.captured.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url == baseURL.appendingPathComponent("api/session"))
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")

        let body = try #require(request.httpBody)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object.count == 3)
        #expect(object["client_id"] as? String == "client-1")
        #expect(object["code_challenge"] as? String == "challenge-1")
        #expect(object["code_challenge_method"] as? String == "S256")
    }

    @Test("createSession decodes a 201 happy path")
    func createSessionHappyPath() async throws {
        let transport = RecordingTransport([
            json(sessionBody(installURL: "https://app.yellowhammer.dev/install/s1"), status: 201)
        ])
        let client = CodeRelayClient(baseURL: baseURL, transport: transport.send)
        let session = try await client.createSession(clientID: "c", codeChallenge: "x")
        #expect(session.sessionID == "s1")
        #expect(session.approvalURL == URL(string: "https://app.yellowhammer.dev/install/s1"))
        #expect(session.expiresIn == .seconds(900))
    }

    @Test("createSession rejects an install_url on another host")
    func createSessionRejectsWrongHost() async throws {
        let transport = RecordingTransport([
            json(sessionBody(installURL: "https://evil.example/install/s1"), status: 201)
        ])
        let client = CodeRelayClient(baseURL: baseURL, transport: transport.send)
        do {
            _ = try await client.createSession(clientID: "c", codeChallenge: "x")
            Issue.record("expected badResponse")
        } catch .badResponse {
            // expected
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("createSession rejects an install_url whose path doesn't match the session")
    func createSessionRejectsMismatchedPath() async throws {
        let transport = RecordingTransport([
            json(sessionBody(installURL: "https://app.yellowhammer.dev/install/other"), status: 201)
        ])
        let client = CodeRelayClient(baseURL: baseURL, transport: transport.send)
        do {
            _ = try await client.createSession(clientID: "c", codeChallenge: "x")
            Issue.record("expected badResponse")
        } catch .badResponse {
            // expected
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("createSession maps 400 to badResponse with the body")
    func createSessionMaps400() async throws {
        let transport = RecordingTransport([json(#"{"error":"invalid client_id"}"#, status: 400)])
        let client = CodeRelayClient(baseURL: baseURL, transport: transport.send)
        do {
            _ = try await client.createSession(clientID: "c", codeChallenge: "x")
            Issue.record("expected badResponse")
        } catch .badResponse(let status, let body) {
            #expect(status == 400)
            #expect(body.contains("invalid client_id"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("createSession maps 429 with Retry-After to rateLimited(.seconds(7))")
    func createSessionMaps429WithRetryAfter() async throws {
        let transport = RecordingTransport([json("{}", status: 429, headers: ["Retry-After": "7"])])
        let client = CodeRelayClient(baseURL: baseURL, transport: transport.send)
        do {
            _ = try await client.createSession(clientID: "c", codeChallenge: "x")
            Issue.record("expected rateLimited")
        } catch .rateLimited(let retryAfter) {
            #expect(retryAfter == .seconds(7))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("createSession maps 429 without Retry-After to rateLimited(nil)")
    func createSessionMaps429WithoutRetryAfter() async throws {
        let transport = RecordingTransport([json("{}", status: 429)])
        let client = CodeRelayClient(baseURL: baseURL, transport: transport.send)
        do {
            _ = try await client.createSession(clientID: "c", codeChallenge: "x")
            Issue.record("expected rateLimited")
        } catch .rateLimited(let retryAfter) {
            #expect(retryAfter == nil)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("createSession maps 503 to unreachable")
    func createSessionMaps503() async throws {
        let transport = RecordingTransport([json("{}", status: 503)])
        let client = CodeRelayClient(baseURL: baseURL, transport: transport.send)
        do {
            _ = try await client.createSession(clientID: "c", codeChallenge: "x")
            Issue.record("expected unreachable")
        } catch .unreachable {
            // expected
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("createSession maps a transport URLError to unreachable")
    func createSessionMapsTransportError() async throws {
        let transport = RecordingTransport([.failure(.notConnectedToInternet)])
        let client = CodeRelayClient(baseURL: baseURL, transport: transport.send)
        do {
            _ = try await client.createSession(clientID: "c", codeChallenge: "x")
            Issue.record("expected unreachable")
        } catch .unreachable {
            // expected
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("createSession maps a surfaced 303 to badResponse")
    func createSessionMaps303() async throws {
        let transport = RecordingTransport([json("{}", status: 303)])
        let client = CodeRelayClient(baseURL: baseURL, transport: transport.send)
        do {
            _ = try await client.createSession(clientID: "c", codeChallenge: "x")
            Issue.record("expected badResponse")
        } catch .badResponse(let status, _) {
            #expect(status == 303)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    // MARK: - status

    @Test("status decodes pending")
    func statusDecodesPending() async throws {
        let transport = RecordingTransport([json(#"{"status":"pending"}"#, status: 200)])
        let client = CodeRelayClient(baseURL: baseURL, transport: transport.send)
        let status = try await client.status(of: "s1")
        #expect(status == .pending)
    }

    @Test("status decodes approved")
    func statusDecodesApproved() async throws {
        let transport = RecordingTransport([json(#"{"status":"approved","code":"abc"}"#, status: 200)])
        let client = CodeRelayClient(baseURL: baseURL, transport: transport.send)
        let status = try await client.status(of: "s1")
        #expect(status == .approved(code: "abc"))
    }

    @Test("status decodes rejected")
    func statusDecodesRejected() async throws {
        let transport = RecordingTransport([json(#"{"status":"rejected","error":"access_denied"}"#, status: 200)])
        let client = CodeRelayClient(baseURL: baseURL, transport: transport.send)
        let status = try await client.status(of: "s1")
        #expect(status == .rejected(error: "access_denied"))
    }

    @Test("status decodes expired")
    func statusDecodesExpired() async throws {
        let transport = RecordingTransport([json(#"{"status":"expired"}"#, status: 200)])
        let client = CodeRelayClient(baseURL: baseURL, transport: transport.send)
        let status = try await client.status(of: "s1")
        #expect(status == .expired)
    }

    @Test("status with an empty approved code is badResponse")
    func statusApprovedWithEmptyCodeIsBadResponse() async throws {
        let transport = RecordingTransport([json(#"{"status":"approved","code":""}"#, status: 200)])
        let client = CodeRelayClient(baseURL: baseURL, transport: transport.send)
        await #expect(throws: CodeRelayClient.RelayError.self) {
            _ = try await client.status(of: "s1")
        }
    }

    @Test("status 404 is expired regardless of body")
    func status404IsExpired() async throws {
        let transport = RecordingTransport([json(#"{"unexpected":"body"}"#, status: 404)])
        let client = CodeRelayClient(baseURL: baseURL, transport: transport.send)
        let status = try await client.status(of: "s1")
        #expect(status == .expired)
    }

    @Test("status maps 429/503/URLError the same as createSession")
    func statusMapsTransportErrors() async throws {
        let rateLimited = RecordingTransport([json("{}", status: 429, headers: ["Retry-After": "3"])])
        let rateLimitedClient = CodeRelayClient(baseURL: baseURL, transport: rateLimited.send)
        do {
            _ = try await rateLimitedClient.status(of: "s1")
            Issue.record("expected rateLimited")
        } catch .rateLimited(let retryAfter) {
            #expect(retryAfter == .seconds(3))
        } catch {
            Issue.record("unexpected error \(error)")
        }

        let unreachable = RecordingTransport([json("{}", status: 503)])
        let unreachableClient = CodeRelayClient(baseURL: baseURL, transport: unreachable.send)
        await #expect(throws: CodeRelayClient.RelayError.self) {
            _ = try await unreachableClient.status(of: "s1")
        }

        let transportError = RecordingTransport([.failure(.notConnectedToInternet)])
        let transportErrorClient = CodeRelayClient(baseURL: baseURL, transport: transportError.send)
        await #expect(throws: CodeRelayClient.RelayError.self) {
            _ = try await transportErrorClient.status(of: "s1")
        }
    }

    @Test("status 500 is badResponse")
    func status500IsBadResponse() async throws {
        let transport = RecordingTransport([json("{}", status: 500)])
        let client = CodeRelayClient(baseURL: baseURL, transport: transport.send)
        do {
            _ = try await client.status(of: "s1")
            Issue.record("expected badResponse")
        } catch .badResponse(let status, _) {
            #expect(status == 500)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("status percent-encodes a session id containing a slash into one path segment")
    func statusPercentEncodesSessionID() async throws {
        let transport = RecordingTransport([json(#"{"status":"pending"}"#, status: 200)])
        let client = CodeRelayClient(baseURL: baseURL, transport: transport.send)
        _ = try await client.status(of: "abc/def")

        let request = try #require(transport.captured.first)
        #expect(request.url?.absoluteString == "https://app.yellowhammer.dev/api/session/abc%2Fdef")
    }
}
