# Networking

Talking to an HTTP or WebSocket API: clients, `URLSession`, the request/response
lifecycle. Companion to **state/injection** (how a client reaches a view),
**state/streams** (consuming a socket in SwiftUI) and **data/persistence** (where a
response lands). `JSONDecoder` configuration and offline caching are yours to own.

## Three rules

1. **All HTTP goes through a client.** A client is a *tiny* library — internal or
   third-party — that wraps one API behind a small, obvious, typed surface:
   `func article(id: Article.ID) async throws -> Article`. This holds for a foreign API
   and for your own backend alike. No view, store or model ever builds a `URLRequest`.
2. **Generate the client from OpenAPI whenever a spec exists.** A hand-written client is
   the fallback, not the default.
3. **A WebSocket client exposes an `AsyncSequence`**, never a delegate or a callback.
   `func events() -> some AsyncSequence<Event, any Error>` is the whole API.

## Prefer generated clients

With an OpenAPI document, use
[swift-openapi-generator](https://github.com/apple/swift-openapi-generator) with the
`URLSession` transport. The spec becomes the source of truth: types, paths, query items
and status codes are generated at build time, so a backend change breaks the build
instead of a screen.

- Keep the generated code out of the repo — run the generator as an SwiftPM build plugin.
- Wrap the generated `Client` in your own narrow protocol anyway. It keeps generated
  response envelopes out of the domain layer, and the feature code stays stubbable.
- If the server publishes no spec, writing one for the endpoints you consume is often
  cheaper than hand-rolling and maintaining a client.

## Hand-written client shape

```swift
protocol ArticleAPI: Sendable {
    func article(id: Article.ID) async throws -> Article
    func articles(matching query: String) async throws -> [Article]
}

actor HTTPArticleAPI: ArticleAPI {
    private let baseURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder

    init(baseURL: URL, session: URLSession, decoder: JSONDecoder = .api) { … }

    func article(id: Article.ID) async throws -> Article {
        try await get("articles/\(id)")
    }
}
```

- **One narrow protocol per capability**, named for the domain, not the transport. The
  live type is the only thing that knows about HTTP; tests and previews get a stub struct.
- **Keep URL building, headers, retries, status mapping and decoding inside the client** —
  in one private `request` helper, not duplicated per endpoint.
- **Clients are `Sendable` and hold no UI state.** `actor` or an immutable `struct`; state
  lives in the store that calls it (see **state/flow**).
- **Return domain types, throw domain errors.** A caller should never see
  `DecodingError`, `URLError` or a status code; map them to a small error enum the UI can
  switch on.

## Request / response lifecycle

- **Build URLs with `URL.appending(path:)` and `URLComponents`**, never string
  interpolation — percent-encoding of query values is the whole point.
- **One `async` call: `session.data(for:)`.** Completion handlers and Combine publishers
  are legacy. Use `session.bytes(for:)` for streamed responses and `download(for:)` /
  `upload(for:fromFile:)` for large payloads.
- **Cast to `HTTPURLResponse` and check the status explicitly.** A 4xx/5xx is a successful
  `URLSession` call; nothing throws unless you do. Decode the server's error body on
  failure — that's where the actionable message is.
- **Send `Accept` / `Content-Type` per request** and put stable headers
  (`User-Agent`, API version, auth) in the session's
  `httpAdditionalHeaders` — configured once, in one place.
- **Configure a session, don't tune `URLSession.shared`.** `URLSessionConfiguration`
  owns `timeoutIntervalForRequest`, `waitsForConnectivity` (prefer it to reachability
  polling), `httpMaximumConnectionsPerHost` and the cache policy. One session per client,
  created once — a session per request leaks connections and defeats HTTP/2 reuse.
- **Cancellation is normal.** `.task` cancels on disappearance, which throws
  `CancellationError` (or `URLError.cancelled`) up through the client; handle it as a
  non-error path and never report it to the user.
- **Retry only idempotent requests, only on transient failures** (timeout, connection
  lost, 429, 5xx), with exponential backoff and jitter, and honour `Retry-After`. Never
  retry a 4xx other than 429, and never blind-retry a POST.
- **Refresh auth in one place.** Serialise token refresh inside the client (an `actor`
  makes this a single stored `Task`) so ten parallel 401s trigger one refresh, not ten.
- **Let HTTP do the caching.** `URLCache` plus server `ETag` / `Cache-Control` beats a
  hand-rolled layer; add your own only for offline reads.
- **Log with OSLog, redact by default.** Never log tokens, bodies with PII, or full
  headers; `privacy: .public` only on the method, path and status.

## WebSockets

```swift
protocol EventFeed: Sendable {
    func events() -> AsyncThrowingStream<Event, any Error>
}

struct WebSocketEventFeed: EventFeed {
    let url: URL
    let session: URLSession

    func events() -> AsyncThrowingStream<Event, any Error> {
        AsyncThrowingStream { continuation in
            let task = session.webSocketTask(with: url)
            let pump = Task {
                task.resume()
                do {
                    while !Task.isCancelled {
                        let message = try await task.receive()
                        continuation.yield(try Event(message))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                pump.cancel()
                task.cancel(with: .goingAway, reason: nil)
            }
        }
    }
}
```

- **`onTermination` is mandatory.** It is the only thing that closes the socket when the
  consumer's `.task` is cancelled; without it the connection outlives the screen.
- **Return a fresh sequence per call and treat it as single-consumer.** For a socket that
  must fan out to several screens, put a single pump in the client and hand out a
  broadcast sequence — do not open one socket per view.
- **Model the connection state as part of the stream** (`case connecting/open/event/…`)
  or expose it as a separate `@Observable` value; a `Bool` set from two places drifts.
- **Reconnect in the client, with backoff and jitter**, and only for unexpected closes —
  a clean `.normalClosure` is a finish, not a failure. The consumer should not have to
  know a reconnect happened.
- **Keepalive:** send an app-level ping on an interval (`sendPing` for the protocol-level
  one) and treat a missing pong as a dead connection. iOS suspends sockets in the
  background; expect to reconnect on foreground rather than trying to stay connected.
- **Send from one place.** Concurrent `send(_:)` calls from several tasks interleave
  frames; funnel them through the client's actor.
- Consume it in SwiftUI with `.task(id:)` — see **state/streams** for the tiering and for
  debounce/merge operators.

## Pitfalls

- **`URLSession.shared` ignores your configuration** — no custom timeout, no extra
  headers, no `waitsForConnectivity`. Fine for a one-off image fetch; wrong as a client's
  session.
- **A non-2xx that decodes anyway** produces a valid-looking empty model. Check the
  status before decoding, always.
- **Decoding on the main actor** stutters scrolling for large payloads. The client is not
  `@MainActor`; keep it that way and let only the store hop back.
- **`Task { }` in a view for a request** escapes the view's lifetime — use `.task`.
- **Retrying inside the store *and* the client** multiplies attempts. Retry lives in the
  client, once.
- **Testing against the network.** Stub the protocol for unit tests; use a
  `URLProtocol` subclass only when the client's own request building is under test.
