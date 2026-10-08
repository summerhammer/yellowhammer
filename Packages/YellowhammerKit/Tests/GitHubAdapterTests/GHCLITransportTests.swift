import Foundation
@testable import GitHubAdapter
import Testing

@Suite("GHCLITransport")
struct GHCLITransportTests {
    private static func get(_ path: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.github.com\(path)")!)
        request.httpMethod = "GET"
        return request
    }

    private static let okResponse = """
        HTTP/2.0 200 OK
        Content-Type: application/json; charset=utf-8
        X-Oauth-Scopes: repo, read:org

        {"login":"octocat"}
        """

    @Test("A 200 is parsed into status, headers and body bytes")
    func parsesOK() async throws {
        let gh = try StubGH(stdout: Self.okResponse)
        defer { gh.remove() }

        let (data, response) = try await GHCLITransport(executable: gh.executable).send(Self.get("/user"))

        #expect(response.statusCode == 200)
        #expect(response.value(forHTTPHeaderField: "X-OAuth-Scopes") == "repo, read:org")
        #expect(response.value(forHTTPHeaderField: "content-type") == "application/json; charset=utf-8")
        #expect(String(bytes: data, encoding: .utf8) == #"{"login":"octocat"}"#)
    }

    @Test("CRLF line endings are tolerated")
    func parsesCRLF() async throws {
        let gh = try StubGH(stdout: "HTTP/1.1 200 OK\r\nX-A: b\r\n\r\nbody")
        defer { gh.remove() }

        let (data, response) = try await GHCLITransport(executable: gh.executable).send(Self.get("/user"))

        #expect(response.statusCode == 200)
        #expect(response.value(forHTTPHeaderField: "X-A") == "b")
        #expect(String(bytes: data, encoding: .utf8) == "body")
    }

    @Test("A 404 exits 1 but is still returned as a 404 response")
    func notFoundIsAResponse() async throws {
        let gh = try StubGH(
            stdout: "HTTP/2.0 404 Not Found\nServer: GitHub.com\n\n{\"message\":\"Not Found\"}",
            stderr: "gh: Not Found (HTTP 404)\n", exitCode: 1
        )
        defer { gh.remove() }

        let (data, response) = try await GHCLITransport(executable: gh.executable).send(Self.get("/repos/x/y"))

        #expect(response.statusCode == 404)
        #expect(String(bytes: data, encoding: .utf8) == #"{"message":"Not Found"}"#)
    }

    @Test("A logged-out gh (exit 4, empty stdout) is a 401 with an empty body")
    func loggedOutIsUnauthorized() async throws {
        let gh = try StubGH(stderr: "To get started with GitHub CLI, please run:  gh auth login\n", exitCode: 4)
        defer { gh.remove() }

        let (data, response) = try await GHCLITransport(executable: gh.executable).send(Self.get("/user"))

        #expect(response.statusCode == 401)
        #expect(data.isEmpty)
    }

    @Test("Another non-zero exit with no HTTP output throws, carrying the exit code and gh's first stderr line")
    func otherFailureThrows() async throws {
        let gh = try StubGH(stderr: "gh: something broke\nsecond line\n", exitCode: 2)
        defer { gh.remove() }

        await #expect(throws: GHCLITransportError.failed(exitCode: 2, detail: "gh: something broke")) {
            _ = try await GHCLITransport(executable: gh.executable).send(Self.get("/user"))
        }
    }

    @Test("A gh that cannot be launched throws launchFailed")
    func launchFailure() async {
        let transport = GHCLITransport(executable: "/nonexistent/dir/gh")
        await #expect(throws: GHCLITransportError.launchFailed) {
            _ = try await transport.send(Self.get("/user"))
        }
    }

    @Test("A host other than api.github.com throws and gh is not run")
    func unsupportedHost() async throws {
        let gh = try StubGH(stdout: Self.okResponse)
        defer { gh.remove() }
        let request = URLRequest(url: URL(string: "https://example.com/user")!)

        await #expect(throws: GHCLITransportError.unsupportedHost) {
            _ = try await GHCLITransport(executable: gh.executable).send(request)
        }
        #expect(!FileManager.default.fileExists(atPath: gh.directory.appendingPathComponent("argv").path))
    }

    @Test("A GET passes -i, -X GET, the headers and the path with its query, and no --input")
    func getArguments() async throws {
        let gh = try StubGH(stdout: Self.okResponse)
        defer { gh.remove() }
        var request = Self.get("/repos/o/r?per_page=5")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        _ = try await GHCLITransport(executable: gh.executable).send(request)

        let arguments = try gh.arguments()
        #expect(arguments == [
            "api", "-i", "-X", "GET", "-H", "Accept: application/vnd.github+json", "/repos/o/r?per_page=5"
        ])
        #expect(!arguments.contains("--input"))
    }

    @Test("The Authorization header is never forwarded, in any casing, but the others are")
    func authorizationIsDropped() async throws {
        let gh = try StubGH(stdout: Self.okResponse)
        defer { gh.remove() }
        var request = Self.get("/user")
        request.setValue("Bearer ghp_sekrit", forHTTPHeaderField: "Authorization")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        _ = try await GHCLITransport(executable: gh.executable).send(request)

        let arguments = try gh.arguments()
        #expect(arguments.contains("X-GitHub-Api-Version: 2022-11-28"))
        #expect(!arguments.contains { $0.lowercased().contains("authorization") })
        #expect(!arguments.contains { $0.contains("ghp_sekrit") })
    }

    @Test("A POST body arrives on stdin behind --input - and is never an argument")
    func postBodyOnStdin() async throws {
        let gh = try StubGH(stdout: "HTTP/2.0 201 Created\n\n{}")
        defer { gh.remove() }
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/o/r/pulls")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = #"{"title":"A title","head":"yh-a","base":"main","body":"text"}"#
        request.httpBody = Data(body.utf8)

        let (_, response) = try await GHCLITransport(executable: gh.executable).send(request)

        #expect(response.statusCode == 201)
        let arguments = try gh.arguments()
        #expect(arguments.starts(with: ["api", "-i", "-X", "POST"]))
        #expect(arguments.last == "/repos/o/r/pulls")
        let inputIndex = try #require(arguments.firstIndex(of: "--input"))
        #expect(arguments[inputIndex + 1] == "-")
        #expect(!arguments.contains { $0.contains("A title") })
        #expect(String(bytes: try gh.stdin(), encoding: .utf8) == body)
    }

    @Test("gh runs with prompts, update notifiers and colour switched off")
    func environment() async throws {
        let gh = try StubGH(stdout: Self.okResponse)
        defer { gh.remove() }

        _ = try await GHCLITransport(executable: gh.executable).send(Self.get("/user"))

        #expect(try gh.environment() == "1|1|1|1")
    }

    @Test("GitHubCredentialCheck over a gh transport authenticates with no token")
    func credentialCheckAuthenticated() async throws {
        let gh = try StubGH(stdout: Self.okResponse)
        defer { gh.remove() }
        let check = GitHubCredentialCheck(transport: GHCLITransport(executable: gh.executable))

        let result = await check.authenticate(token: nil)

        #expect(result == .authenticated(login: "octocat", scopes: ["repo", "read:org"]))
        #expect(try gh.arguments().last == "/user")
    }

    @Test("GitHubCredentialCheck over a logged-out gh is rejected")
    func credentialCheckLoggedOut() async throws {
        let gh = try StubGH(stderr: "To get started with GitHub CLI, please run:  gh auth login\n", exitCode: 4)
        defer { gh.remove() }
        let check = GitHubCredentialCheck(transport: GHCLITransport(executable: gh.executable))

        #expect(await check.authenticate(token: nil) == .rejected)
        #expect(await check.access(token: nil, owner: "o", repository: "r", scopes: nil) == .rejected)
    }

    @Test("A nil token sends no Authorization header over any transport")
    func nilTokenSendsNoAuthorization() async throws {
        let stub = RoutedStubTransport(.reply(200, body: #"{"login":"octocat"}"#))
        _ = await GitHubCredentialCheck(transport: stub).authenticate(token: nil)
        _ = await GitHubCredentialCheck(transport: stub)
            .access(token: nil, owner: "o", repository: "r", scopes: nil)

        let requests = await stub.requests
        #expect(requests.count == 2)
        for request in requests {
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        }
    }
}
