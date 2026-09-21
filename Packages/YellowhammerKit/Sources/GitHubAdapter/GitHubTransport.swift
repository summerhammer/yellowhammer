import Foundation

/// Sends one HTTP request. The seam that lets the adapter be tested without a network. Mirrors
/// `LinearAdapter`'s own `HTTPTransport`, kept separate so this module never imports `LinearAdapter`
/// (an adapter module imports only `Domain`).
public protocol GitHubTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// The production transport.
public struct URLSessionGitHubTransport: GitHubTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}
