@testable import EngineCommand
import Foundation
import Testing

// roadmap P17.6 slice (a) (spec: board-projection/install-the-linear-app "The install", OQ93/OQ94): the
// loopback listener that receives the OAuth redirect. Tests use an ephemeral high port the test itself
// chooses — never 44837–44839, so a test run never collides with a real setup run on the same Mac.

@Suite("LoopbackCallbackServer (P17.6)")
struct LoopbackCallbackServerTests {
    /// A port unlikely to be in use, well away from the three real redirect ports.
    private static func testPort() -> Int {
        Int.random(in: 51000...59000)
    }

    @Test("Serves /callback with its query, then closes")
    func servesCallback() async throws {
        let port = Self.testPort()
        let server = try LoopbackCallbackServer.bind(port: port)
        defer { server.close() }

        async let result = server.waitForCallback(timeout: .seconds(5))

        let url = URL(string: "http://127.0.0.1:\(port)/callback?code=abc123&state=xyz789")!
        let (_, response) = try await URLSession.shared.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)

        let callback = try await result
        #expect(callback.code == "abc123")
        #expect(callback.state == "xyz789")
        #expect(callback.error == nil)
    }

    @Test("404s another path, then still accepts /callback on a later connection")
    func fourOhFoursThenAccepts() async throws {
        let port = Self.testPort()
        let server = try LoopbackCallbackServer.bind(port: port)
        defer { server.close() }

        async let result = server.waitForCallback(timeout: .seconds(5))

        let otherURL = URL(string: "http://127.0.0.1:\(port)/robots.txt")!
        let (_, otherResponse) = try await URLSession.shared.data(from: otherURL)
        #expect((otherResponse as? HTTPURLResponse)?.statusCode == 404)

        let callbackURL = URL(string: "http://127.0.0.1:\(port)/callback?code=ok&state=st")!
        let (_, response) = try await URLSession.shared.data(from: callbackURL)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)

        let callback = try await result
        #expect(callback.code == "ok")
    }

    @Test("An error callback carries error and error_description")
    func servesErrorCallback() async throws {
        let port = Self.testPort()
        let server = try LoopbackCallbackServer.bind(port: port)
        defer { server.close() }

        async let result = server.waitForCallback(timeout: .seconds(5))

        let url = URL(string: "http://127.0.0.1:\(port)/callback?error=access_denied&state=st")!
        _ = try await URLSession.shared.data(from: url)

        let callback = try await result
        #expect(callback.error == "access_denied")
        #expect(callback.code == nil)
    }

    @Test("Binding a port another socket already holds is reported busy")
    func bindingBusyPortFails() throws {
        let port = Self.testPort()
        let first = try LoopbackCallbackServer.bind(port: port)
        defer { first.close() }

        #expect(throws: LoopbackCallbackServer.BindError.busy(port: port)) {
            try LoopbackCallbackServer.bind(port: port)
        }
    }

    @Test("A wait with nothing connecting ends in a distinct timeout error")
    func waitTimesOut() async throws {
        let port = Self.testPort()
        let server = try LoopbackCallbackServer.bind(port: port)
        defer { server.close() }

        await #expect(throws: LoopbackCallbackServer.WaitError.timedOut) {
            try await server.waitForCallback(timeout: .milliseconds(200))
        }
    }

    @Test("Cancelling the waiting Task ends the wait with a distinct cancellation error")
    func waitCancels() async throws {
        let port = Self.testPort()
        let server = try LoopbackCallbackServer.bind(port: port)
        defer { server.close() }

        let task = Task<LoopbackCallbackServer.CallbackResult, Error> {
            try await server.waitForCallback(timeout: .seconds(30))
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()

        await #expect(throws: LoopbackCallbackServer.WaitError.cancelled) {
            try await task.value
        }
    }
}
