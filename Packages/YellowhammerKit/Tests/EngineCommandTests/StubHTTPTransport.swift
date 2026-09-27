import Foundation
import Synchronization

/// Plays back scripted HTTP replies in order — `LinearInstallFlowTests`'s own copy of
/// `LinearAdapterTests/StubHTTPTransport.swift` (test-only types are not exported across targets). Not
/// declared to conform to `LinearAdapter`'s `HTTPTransport` protocol: `EngineCommandTests` may not
/// import an adapter (MB2), so `send` is passed to `LinearInstallFlow` as a plain closure instead.
final class StubHTTPTransport: Sendable {
    enum Reply: Sendable {
        case response(status: Int, headers: [String: String], body: Data)
        case failure(URLError.Code)
    }

    private let replies: Mutex<[Reply]>

    init(_ replies: [Reply]) {
        self.replies = Mutex(replies)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let reply = replies.withLock { $0.isEmpty ? nil : $0.removeFirst() }
        switch reply {
        case .response(let status, let headers, let body)?:
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers
            )!
            return (body, response)
        case .failure(let code)?:
            throw URLError(code)
        case nil:
            throw URLError(.cannotConnectToHost)
        }
    }
}

/// The token/GraphQL reply shapes `LinearInstallFlowTests` needs.
enum InstallFlowFixture {
    static func json(_ body: String, status: Int = 200) -> StubHTTPTransport.Reply {
        .response(status: status, headers: ["Content-Type": "application/json"], body: Data(body.utf8))
    }

    static func installationGrant(
        accessToken: String, refreshToken: String, expiresIn: Int = 7200
    ) -> StubHTTPTransport.Reply {
        json("""
            {"access_token":"\(accessToken)","refresh_token":"\(refreshToken)",
             "token_type":"Bearer","expires_in":\(expiresIn)}
            """)
    }
}
