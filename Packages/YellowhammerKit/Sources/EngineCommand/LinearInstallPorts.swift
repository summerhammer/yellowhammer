import Foundation
import LinearAdapter
import System
import Subprocess

/// Picking the first free loopback port of the three the Linear App Installation registers (roadmap
/// P17.6; spec: board-projection/install-the-linear-app "The install", OQ94). All three busy is not a
/// retryable-per-port condition: setup stops before the browser and asks the Operator to quit one.

/// The process bound to a busy port, from `lsof` — nil when `lsof` itself could not answer (the port is
/// still reported busy either way).
public struct PortHolder: Sendable, Equatable {
    public let pid: Int32
    public let command: String

    public init(pid: Int32, command: String) {
        self.pid = pid
        self.command = command
    }
}

/// All three fixed ports were bound by another process. Named in order, each with its holder when
/// `lsof` could identify one.
public struct PortsBusyError: Error, Sendable, Equatable {
    public let ports: [(port: Int, holder: PortHolder?)]

    public init(_ ports: [(port: Int, holder: PortHolder?)]) {
        self.ports = ports
    }

    public static func == (lhs: PortsBusyError, rhs: PortsBusyError) -> Bool {
        lhs.ports.map(Row.init) == rhs.ports.map(Row.init)
    }

    private struct Row: Equatable {
        let port: Int
        let holder: PortHolder?
        init(_ pair: (port: Int, holder: PortHolder?)) {
            port = pair.port
            holder = pair.holder
        }
    }
}

/// A bound, listening loopback server, abstracted so `LinearInstallFlow`'s tests inject a fake that
/// never opens a real socket.
public protocol CallbackListening: Sendable {
    var port: Int { get }
    var redirectURI: URL { get }
    func waitForCallback(timeout: Duration) async throws -> LoopbackCallbackServer.CallbackResult
    func close()
}

extension LoopbackCallbackServer: CallbackListening {}

/// Looks up the process holding a busy TCP port, via `lsof`. An injectable seam: `LinearInstallFlow`'s
/// tests feed canned `-Fpc` output instead of running the real binary.
public protocol PortHolderLookup: Sendable {
    func holder(port: Int) async -> PortHolder?
}

/// The production lookup: `lsof -nP -iTCP:<port> -sTCP:LISTEN -Fpc`, parsing the `p` (pid) and `c`
/// (command) fields. Any failure — `lsof` missing, non-zero exit, unparseable output — reports no
/// holder; the port is still busy either way, so this never blocks reporting it.
public struct LSOFPortHolderLookup: PortHolderLookup {
    private let lsofPath: String

    public init(lsofPath: String = "/usr/sbin/lsof") {
        self.lsofPath = lsofPath
    }

    public func holder(port: Int) async -> PortHolder? {
        let arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpc"]
        guard
            let result = try? await Subprocess.run(
                .path(FilePath(lsofPath)), arguments: Arguments(arguments),
                output: .string(limit: 4096), error: .discarded
            ),
            case .exited(0) = result.terminationStatus
        else {
            return nil
        }
        return Self.parse(result.standardOutput)
    }

    /// `-Fpc` output: one `p<pid>` line, then one `c<command>` line, per matching process.
    static func parse(_ output: String) -> PortHolder? {
        var pid: Int32?
        var command: String?
        for line in output.split(separator: "\n") {
            guard let marker = line.first else { continue }
            let value = String(line.dropFirst())
            switch marker {
            case "p": pid = Int32(value)
            case "c": command = value
            default: break
            }
        }
        guard let pid else { return nil }
        return PortHolder(pid: pid, command: command ?? "unknown")
    }
}

/// The three fixed loopback ports and their redirect URIs, re-exposed here (rather than requiring an
/// `import LinearAdapter`) so `EngineCommandTests` — which may not import an adapter (MB2) — can name
/// them.
public enum LinearInstallPortsConfiguration {
    public static let ports = LinearAppInstallation.redirectPorts
    public static func redirectURI(forPort port: Int) -> URL { LinearAppInstallation.redirectURI(forPort: port) }
}

/// Tries each port in order; the first that binds wins. All busy → `PortsBusyError` naming each port
/// and its holder.
enum LoopbackPortSelection {
    static func select(
        ports: [Int] = LinearInstallPortsConfiguration.ports,
        binder: (Int) throws -> any CallbackListening,
        holderLookup: any PortHolderLookup
    ) async throws -> any CallbackListening {
        var busy: [(port: Int, holder: PortHolder?)] = []
        for port in ports {
            do {
                return try binder(port)
            } catch let error as LoopbackCallbackServer.BindError {
                switch error {
                case .busy:
                    busy.append((port, await holderLookup.holder(port: port)))
                case .failed(let failedPort, let reason):
                    // Not EADDRINUSE — the socket call itself failed. This is not "another process
                    // holds the port": surface it distinctly rather than folding it into "busy".
                    throw LoopbackCallbackServer.BindError.failed(port: failedPort, reason: reason)
                }
            }
        }
        throw PortsBusyError(busy)
    }
}
