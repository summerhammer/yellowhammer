import Foundation
import Subprocess
import System

/// Why ``GHCLITransport`` could not produce a response.
public enum GHCLITransportError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The request was for a host other than `api.github.com`; `gh api` is only ever pointed at github.com.
    case unsupportedHost
    /// `gh` could not be started (missing, not executable).
    case launchFailed
    /// `gh` printed no HTTP response and did not exit with the logged-out code. `detail` is the first line
    /// of its standard error, which names no token.
    case failed(exitCode: Int32, detail: String)

    public var description: String {
        switch self {
        case .unsupportedHost:
            return "gh was asked for a host other than api.github.com"
        case .launchFailed:
            return "gh could not be started"
        case .failed(let exitCode, let detail):
            return detail.isEmpty ? "gh exited with status \(exitCode)" : "gh exited with status \(exitCode): \(detail)"
        }
    }
}

/// A ``GitHubTransport`` that sends each request through the Operator's own GitHub CLI (`gh api -i`), so
/// Yellowhammer holds no token: `gh` authenticates as its active account.
///
/// Yellowhammer never runs `gh auth token`, `gh auth switch`, `gh auth logout` or anything else that changes
/// `gh`'s state; this transport only issues `gh api`.
public struct GHCLITransport: GitHubTransport {
    /// Collected standard output is capped here; a `gh` printing more fails the call.
    static let outputLimit = 16 * 1024 * 1024
    /// Collected standard error is capped here.
    static let errorLimit = 64 * 1024
    /// The exit code `gh` uses when it is not logged in.
    static let loggedOutExitCode: Int32 = 4

    private let executable: String

    /// `executable` is the absolute path of `gh`.
    public init(executable: String) {
        self.executable = executable
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let arguments = try Self.arguments(for: request)
        let result = try await run(arguments, input: request.httpBody ?? Data())

        if let parsed = Self.parse(result.stdout, url: request.url) {
            // A 404 exits 1 but is still a response: the exit code is only consulted when none was printed.
            return parsed
        }
        if result.exitCode == Self.loggedOutExitCode, let url = request.url,
           let unauthorized = HTTPURLResponse(url: url, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: [:]) {
            // A logged-out gh is the same verdict as an unauthenticated request, so GitHubCredentialCheck
            // reports `.rejected` and the adapter reports missing or insufficient credentials.
            return (Data(), unauthorized)
        }
        throw GHCLITransportError.failed(exitCode: result.exitCode, detail: result.firstErrorLine)
    }

    // MARK: Arguments

    /// `api -i -X <METHOD> -H "<Name>: <value>"... [--input -] </path?query>`. The body is never an argument.
    static func arguments(for request: URLRequest) throws -> [String] {
        guard
            let url = request.url,
            url.scheme == "https", url.host == "api.github.com",
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            throw GHCLITransportError.unsupportedHost
        }
        var arguments = ["api", "-i", "-X", request.httpMethod ?? "GET"]
        for (name, value) in (request.allHTTPHeaderFields ?? [:]).sorted(by: { $0.key < $1.key }) {
            // Dropped on purpose: GitHubCredentialCheck and GitHubAdapter may still set an Authorization
            // header, but gh authenticates as its active account and must never be handed a token.
            if name.caseInsensitiveCompare("Authorization") == .orderedSame { continue }
            arguments += ["-H", "\(name): \(value)"]
        }
        if let body = request.httpBody, !body.isEmpty {
            arguments += ["--input", "-"]
        }
        var path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        if let query = components.percentEncodedQuery, !query.isEmpty {
            path += "?\(query)"
        }
        arguments.append(path)
        return arguments
    }

    // MARK: Running

    private struct RunResult {
        let exitCode: Int32
        let stdout: [UInt8]
        let stderr: [UInt8]

        var firstErrorLine: String {
            let text = String(validating: stderr, as: UTF8.self) ?? ""
            return text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        }
    }

    private func run(_ arguments: [String], input: Data) async throws -> RunResult {
        var platformOptions = PlatformOptions()
        platformOptions.teardownSequence = [.send(signal: .terminate, allowedDurationToNextStep: .milliseconds(50))]
        let environment = Environment.inherit.updating([
            "GH_PROMPT_DISABLED": "1",
            "GH_NO_UPDATE_NOTIFIER": "1",
            "GH_NO_EXTENSION_UPDATE_NOTIFIER": "1",
            "NO_COLOR": "1"
        ])
        do {
            let result = try await Subprocess.run(
                .path(FilePath(executable)),
                arguments: Arguments(arguments),
                environment: environment,
                platformOptions: platformOptions,
                input: .data(input),
                output: .bytes(limit: Self.outputLimit),
                error: .bytes(limit: Self.errorLimit)
            )
            let exitCode: Int32
            switch result.terminationStatus {
            case .exited(let code), .signaled(let code):
                exitCode = code
            }
            return RunResult(exitCode: exitCode, stdout: result.standardOutput, stderr: result.standardError)
        } catch let error as SubprocessError
            where [.spawnFailed, .executableNotFound, .failedToChangeWorkingDirectory].contains(error.code) {
            throw GHCLITransportError.launchFailed
        } catch let error as SubprocessError {
            throw GHCLITransportError.failed(exitCode: -1, detail: "gh did not finish (\(error.code))")
        }
    }

    // MARK: Parsing

    /// Parses `gh api -i` output: a status line `HTTP/<ver> <code> <reason>`, `Name: value` header lines up
    /// to the first empty line (LF or CRLF), then the body bytes. Nil when stdout carries no status line.
    static func parse(_ stdout: [UInt8], url: URL?) -> (Data, HTTPURLResponse)? {
        var cursor = 0
        func nextLine() -> String? {
            guard cursor < stdout.count else { return nil }
            let end = stdout[cursor...].firstIndex(of: UInt8(ascii: "\n")) ?? stdout.count
            var line = stdout[cursor..<end]
            if line.last == UInt8(ascii: "\r") { line = line.dropLast() }
            cursor = min(end + 1, stdout.count)
            return String(validating: line, as: UTF8.self) ?? ""
        }

        guard
            let url,
            let statusLine = nextLine(),
            statusLine.hasPrefix("HTTP/")
        else {
            return nil
        }
        let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2, let status = Int(parts[1]) else { return nil }
        let version = String(parts[0])

        var headers: [String: String] = [:]
        while let line = nextLine(), !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon])
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = headers[name].map { "\($0), \(value)" } ?? value
        }

        guard let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: version, headerFields: headers
        ) else {
            return nil
        }
        return (Data(stdout[cursor...]), response)
    }
}
