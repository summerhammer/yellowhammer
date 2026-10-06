import Darwin
import Foundation
import LinearAdapter
import Synchronization

/// The loopback HTTP listener that receives the OAuth redirect during the Linear Board Connection
/// (roadmap P17.6; spec: board-projection/install-the-linear-app, OQ93 (a)). Binds **127.0.0.1** only —
/// never `0.0.0.0` or `::` — on one caller-given port, with plain POSIX sockets so the exact bind
/// behaviour (no `SO_REUSEPORT`, so a genuinely busy port fails to bind rather than sharing it) is
/// under this module's control rather than a higher-level framework's.
///
/// Serves exactly the first `GET /callback?...` request on the accepted connection: any other path gets
/// a `404` and the listener keeps waiting for the next connection. A wait timeout and a cancelled Task
/// both end the wait with a distinct error, and both close the listening socket — no leaked descriptor
/// either way.
public final class LoopbackCallbackServer: Sendable {
    /// What the redirect's query string carried.
    public struct CallbackResult: Sendable, Equatable {
        public let code: String?
        public let state: String?
        public let error: String?
        public let errorDescription: String?

        public init(code: String?, state: String?, error: String?, errorDescription: String?) {
            self.code = code
            self.state = state
            self.error = error
            self.errorDescription = errorDescription
        }
    }

    public enum BindError: Error, Sendable, Equatable {
        /// `EADDRINUSE`: another process already holds this port.
        case busy(port: Int)
        case failed(port: Int, reason: String)
    }

    public enum WaitError: Error, Sendable, Equatable {
        case timedOut
        case cancelled
        case acceptFailed(String)
    }

    public let port: Int
    /// The exact redirect URI this listener answers to — Linear matches a loopback redirect URI
    /// exactly, port included (OQ93 (a)).
    public var redirectURI: URL { LinearAppInstallation.redirectURI(forPort: port) }

    private let descriptor: Mutex<Int32>
    private let closed = Mutex(false)

    private init(port: Int, descriptor: Int32) {
        self.port = port
        self.descriptor = Mutex(descriptor)
    }

    /// Binds and listens on `127.0.0.1:port`. No `SO_REUSEPORT`: a port another process holds must
    /// fail to bind, not silently share it.
    public static func bind(port: Int) throws(BindError) -> LoopbackCallbackServer {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw .failed(port: port, reason: String(cString: strerror(errno))) }

        var reuseAddr: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuseAddr, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let failureErrno = errno
            Darwin.close(fd)
            if failureErrno == EADDRINUSE { throw .busy(port: port) }
            throw .failed(port: port, reason: String(cString: strerror(failureErrno)))
        }
        guard listen(fd, 1) == 0 else {
            let reason = String(cString: strerror(errno))
            Darwin.close(fd)
            throw .failed(port: port, reason: reason)
        }
        return LoopbackCallbackServer(port: port, descriptor: fd)
    }

    /// Closes the listening socket. Safe to call more than once, and safe to call from a cancellation
    /// handler concurrently with the accept loop: it is what unblocks a blocked `accept`/`poll`.
    public func close() {
        let fd = descriptor.withLock { current -> Int32? in
            guard current >= 0 else { return nil }
            let value = current
            current = -1
            return value
        }
        if let fd { Darwin.close(fd) }
        closed.withLock { $0 = true }
    }

    /// Waits for the first `/callback` request. The blocking `accept`/`poll` wait runs on a GCD global
    /// queue, off Swift's cooperative thread pool (mirrors `MachineLock`). A cancelled Task and an
    /// elapsed timeout both close the listening socket and end the wait with a distinct error.
    public func waitForCallback(timeout: Duration = .seconds(600)) async throws -> CallbackResult {
        let cancelled = Mutex(false)
        return try await withTaskCancellationHandler(
            operation: {
                typealias Continuation = CheckedContinuation<CallbackResult, Error>
                return try await withCheckedThrowingContinuation { (continuation: Continuation) in
                    DispatchQueue.global(qos: .userInitiated).async {
                        do {
                            let result = try self.acceptLoop(timeout: timeout, cancelled: cancelled)
                            continuation.resume(returning: result)
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            },
            onCancel: {
                cancelled.withLock { $0 = true }
                self.close()
            }
        )
    }

    /// Polls the listening socket in bounded slices (rather than a single blocking `accept`) so the
    /// timeout and the cancellation flag are both re-checked between connections, with no need for a
    /// second racing Task.
    private func acceptLoop(timeout: Duration, cancelled: borrowing Mutex<Bool>) throws -> CallbackResult {
        let components = timeout.components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            if cancelled.withLock({ $0 }) { throw WaitError.cancelled }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw WaitError.timedOut }
            guard let fd = descriptor.withLock({ $0 >= 0 ? $0 : nil }) else { throw WaitError.cancelled }

            guard let client = try acceptOneConnection(fd: fd, remaining: remaining, cancelled: cancelled) else {
                continue
            }
            defer { Darwin.close(client) }
            if let result = try serve(client: client) {
                return result
            }
        }
    }

    /// One `poll` slice, then one `accept`: nil when nothing connected within this slice (the caller
    /// loops to re-check the deadline and cancellation), the client descriptor once one has.
    private func acceptOneConnection(
        fd: Int32, remaining: TimeInterval, cancelled: borrowing Mutex<Bool>
    ) throws -> Int32? {
        var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let sliceMilliseconds = Int32(min(remaining, 0.5) * 1000)
        let pollResult = poll(&pollFD, 1, sliceMilliseconds)
        if pollResult < 0 {
            if errno == EINTR { return nil }
            throw WaitError.acceptFailed(String(cString: strerror(errno)))
        }
        guard pollResult > 0 else { return nil }

        var clientAddress = sockaddr()
        var length = socklen_t(MemoryLayout<sockaddr>.size)
        let client = accept(fd, &clientAddress, &length)
        guard client >= 0 else {
            if cancelled.withLock({ $0 }) { throw WaitError.cancelled }
            return nil
        }
        return client
    }

    /// Reads one HTTP request off `client`. `/callback` is answered and returns its parsed query;
    /// anything else gets a `404` and returns nil, so the caller's loop keeps waiting.
    private func serve(client: Int32) throws -> CallbackResult? {
        guard let requestLine = try readRequestLine(client) else { return nil }
        let parts = requestLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else { return nil }
        let target = String(parts[1])

        guard
            let components = URLComponents(string: "http://127.0.0.1\(target)"),
            components.path == "/callback"
        else {
            respond(client, status: "404 Not Found", body: "not found")
            return nil
        }

        let items = components.queryItems ?? []
        func value(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }
        let result = CallbackResult(
            code: value("code"), state: value("state"), error: value("error"),
            errorDescription: value("error_description")
        )
        let body = result.error == nil
            ? "Yellowhammer: you can close this tab."
            : (result.errorDescription ?? result.error ?? "an error occurred")
        respond(client, status: "200 OK", body: body)
        return result
    }

    /// Reads until the request line's terminating CRLF (or LF), draining the rest of the headers up to
    /// a blank line so the client's write completes cleanly. Bounded to 8 KB: this is a redirect from
    /// Linear's own browser flow, never an adversarial input.
    private func readRequestLine(_ client: Int32) throws -> String? {
        var buffer = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 512)
        while buffer.count < 8192 {
            let bytesRead = chunk.withUnsafeMutableBytes { pointer in
                read(client, pointer.baseAddress, pointer.count)
            }
            guard bytesRead > 0 else { break }
            buffer.append(contentsOf: chunk[0..<bytesRead])
            if let terminatorStart = Self.findTerminator(in: buffer) {
                buffer.removeSubrange(terminatorStart..<buffer.endIndex)
                break
            }
        }
        guard let text = String(bytes: buffer, encoding: .utf8) else { return nil }
        guard let firstLine = text.split(separator: "\r\n").first else { return nil }
        return String(firstLine)
    }

    /// The index where a `\r\n\r\n` terminator starts, if `buffer` contains one.
    private static func findTerminator(in buffer: [UInt8]) -> Int? {
        guard buffer.count >= 4 else { return nil }
        let terminator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
        for start in 0...(buffer.count - 4) where Array(buffer[start..<(start + 4)]) == terminator {
            return start
        }
        return nil
    }

    private func respond(_ client: Int32, status: String, body: String) {
        let html = "<html><body>\(body)</body></html>"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
        let bytes = Array(response.utf8)
        bytes.withUnsafeBytes { pointer in
            var offset = 0
            while offset < pointer.count {
                let written = write(client, pointer.baseAddress!.advanced(by: offset), pointer.count - offset)
                guard written > 0 else { break }
                offset += written
            }
        }
    }
}
