# Streams

Consuming `AsyncSequence` from SwiftUI. Companion to `.task` (one-shot `async` work) and
**state/primitives** (`@Observable`).

## Pick a tier

| Situation | Use |
|---|---|
| One sequence, state belongs to the view, dies with the view | `.task` / `.task(id:)` + `@State` |
| Needs debounce, throttle, dedupe, retry, or several sources combined | [swift-async-algorithms](https://github.com/apple/swift-async-algorithms) operators inside that same `.task` |
| State belongs to a model — named, shared, refreshable, composed, testable | [StreamUI](https://github.com/rozd/stream-ui) (`StreamValue` + `StreamBuilder`) |

One rule spans all three: **never start a free-running `Task` to consume a stream.**
Every subscription lives inside a `.task(id:)` so SwiftUI cancels it on disappearance
and restarts it when identity changes. There is nothing to leak and nothing to forget
to cancel.

## Tier 1 — view-owned

```swift
struct TickerView: View {
    let symbol: String
    @State private var quote: Quote?
    @Environment(QuoteClient.self) private var client

    var body: some View {
        QuoteRow(quote: quote)
            .task(id: symbol) {                 // restarts when symbol changes
                do {
                    for try await q in client.quotes(for: symbol) {
                        quote = q                // @MainActor: `.task` inherits view isolation
                    }
                } catch is CancellationError {
                    return                       // cancellation is a normal path, not an error
                } catch {
                    // surface a real failure
                }
            }
    }
}
```

- `.task` for load-on-appear; `.task(id:)` whenever a query, selection, or identifier
  drives the stream.
- Never iterate a sequence from `body`, `onAppear` + `Task {}`, or a stored `Task`.
- Keep the loop body a pure state write. Anything heavier belongs in the sequence
  (tier 2) or a model (tier 3).

## Tier 2 — compose policy into the sequence

Put debouncing, deduping, and combining in the *sequence*, not in the view. The view
keeps a single `for await` loop.

```swift
import AsyncAlgorithms

.task(id: query) {
    for await q in AsyncStream(queryStream)        // typed stream of the search text
        .debounce(for: .milliseconds(250))
        .removeDuplicates()
    {
        results = (try? await client.search(q)) ?? []
    }
}
```

Operators worth knowing:

| Operator | Use |
|---|---|
| `debounce(for:)` | Wait for a pause — search fields, typeahead |
| `throttle(for:latest:)` | Cap emission rate — scroll position, sensor data |
| `removeDuplicates()` | Drop no-op emissions before they invalidate a view |
| `combineLatest(a, b, …)` | Render from several live sources as one state |
| `merge(a, b)` | Same-typed sources into one timeline |
| `chunked(by:)` | Batch bursts (by count, or by an `AsyncTimerSequence`) |
| `.map { @MainActor in … }` | Decode/transform in the pipeline, not in the view |

Retry is a loop around the subscription, expressed once in the factory:

```swift
func quotes(for symbol: String) -> some AsyncSequence<Quote, any Error> & Sendable {
    AsyncThrowingStream { continuation in … }   // or the adapter's stream
        .retry(backoff: .exponential(base: .seconds(1), max: .seconds(30)))
}
```

(`retry` is app-side; AsyncAlgorithms ships the rate-limit and combination
operators — write retry as a small `AsyncSequence` wrapper and keep it with the client.)

`merge`/`zip`/`buffer` run their bases on unstructured tasks internally; that is fine
*because* the whole pipeline is consumed inside a `.task(id:)` that cancels them.

## Tier 3 — model-owned streams (StreamUI)

Reach for [StreamUI](https://github.com/rozd/stream-ui) when the streamed state has a
name: shared across views, refreshable, composed from several sources, or tested
independently. It still borrows the view's `.task(id:)` — the kit owns no `Task`s.

```swift
// Store: named after the data. The factory is re-invoked on every run,
// so it must build a FRESH sequence each time.
@Observable
final class Memberships: StreamValue<[Membership]> {
    init(user: User) {
        super.init {
            combineLatest(user.infos, plans(for: user))
                .map { @MainActor in try Membership.build($0, $1) }
        }
    }
}

// View: exhaustive switch over empty | value | error, subscription included.
struct MembershipsScreen: View {
    @State private var memberships: Memberships     // view OWNS the store

    var body: some View {
        StreamBuilder(memberships) { list in
            List(list) { MembershipCard(membership: $0) }
        } empty: {
            ProgressView()
        } error: { error in
            ErrorView(error: error) { memberships.refresh() }
        }
    }
}
```

Core contracts:

- **`StreamValue<T>`** holds `state: StreamState<T>` — `.empty` → `.value` / `.error`.
  `run()` is called *only* from `.task(id: runID)`.
- **`refresh()`** is the single restart verb: clears state, bumps the generation, every
  observing task restarts. Use it for retry buttons and parameter changes.
- **`makeStream()` over a factory closure** when the query depends on a mutable
  property — a closure capturing an init parameter freezes that value forever. Override
  it and `refresh()` from the property's `didSet`.
- **One writer per state.** Streamed state is written only by the stream. Flow state
  that must survive emissions (purchase progress, transient banners) lives in *separate*
  observed properties beside it, never inside the payload — an emission would clobber it
  mid-flow.
- **`patch`** is an ephemeral local override for optimistic UI; the next emission
  replaces it, so always pair it with a durable write.
- **Writes** go through `FutureValue` / `SideEffect`, not through a `StreamValue`.
- `StreamBuilder(id:stream:)` renders a bare `AsyncSequence` keyed by an `Equatable` id
  when nothing needs to own the state and there is no refresh requirement.
- `.observing(store)` is the modifier form for views that read `store.state` directly.
- Construct the store where it is **owned** (`@State`, or the environment). Building one
  inline in a parent's `body` makes a new instance per render and restarts the
  subscription every time.

Lifecycle: appear → subscribe; disappear → cancelled; re-appear → new run, **last value
kept** (no loading flash) and a stale `.error` cleared to `.empty`.

## Pitfalls

- A stored `Task` consuming a stream — it outlives the view and writes to dead state.
- Treating `CancellationError` as a user-facing failure.
- Debouncing with `Task.sleep` scattered through the view instead of `debounce` in the
  pipeline.
- Streaming into a payload that also carries flow state (tier 3, single-writer).
- A factory that returns a stored sequence instead of building a fresh one — the second
  run gets an already-consumed sequence.
