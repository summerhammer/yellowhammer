# StreamUI (Reactive Streams → Views)

**Mandatory.** Long-lived `AsyncSequence` data reaches SwiftUI through
[StreamUI](https://github.com/rozd/stream-ui). Do not hand-roll subscription plumbing.
Companion to **state/streams** (the plain-SwiftUI tiers underneath) and
**state/injection** (how a stream source reaches a view).

iOS 18+ / macOS 15+.

## Rules

- **Never** use Combine (`ObservableObject`, `@Published`, `AnyCancellable`, `sink`) for
  app data flow.
- **Never** start a free-running `Task { for await … }`, or store one in a property.
  Every subscription runs inside a SwiftUI `.task(id:)` that StreamUI attaches for you —
  there is nothing to cancel manually, and no `onDisappear` teardown.
- **Never** hand-write `isLoading` / `error` / `data` triplets. State is the `empty |
  value | error` enum, rendered by an exhaustive switch.
- **Single writer:** streamed state is written only by the stream. Flow state that must
  survive emissions (purchase progress, transient banners) lives in *separate* observed
  properties on the store, never inside the streamed payload.
- Writes do not belong in a `StreamValue`. Use `FutureValue` for one-shot operations and
  `SideEffect` for injectable async work.
- The store must be **owned** (`@State` in a screen, or the environment). Constructing
  one inline in a parent's `body` restarts the subscription on every render.

## Store

Name the store after the data it streams. The factory closure is re-invoked on every
run, so it must build a **fresh** sequence each time.

```swift
@Observable
final class Memberships: StreamValue<[Membership]> {
    init(user: User) {
        super.init {
            user.infos
                .compactMap { $0?.id }
                .flatMap { userId in membershipsStream(for: userId) }
        }
    }
}
```

When the query depends on a **mutable** property, do not capture it in the factory (init
capture freezes the value). Override `makeStream()` — it reads current values on every
run — and call `refresh()` on change:

```swift
var date: Date { didSet { refresh() } }
override func makeStream() -> S { … reads self.date … }
```

## View

```swift
struct MembershipsScreen: View {
    @State private var memberships: Memberships

    var body: some View {
        StreamBuilder(memberships) { memberships in
            List(memberships) { MembershipCard(membership: $0) }
        } empty: {
            ProgressView()
        } error: { error in
            NetworkErrorView(error: error) { memberships.refresh() }
        }
    }
}
```

For a view that renders `stream.state` itself, use `.observing(stream)` (sugar for
`.task(id: stream.runID) { await stream.run() }`; accepts `nil` for lazily-created
stores). For state nothing needs to own or retry, use the id-keyed form:
`StreamBuilder(id:stream:value:empty:error:)`.

## API

| Member | Role |
| --- | --- |
| `state` | `.empty` → `.value(T)` / `.error`. Helpers: `data`, `when(value:error:empty:)`, `maybeWhen(…:orElse:)`, `whenValue(_:)`. |
| `runID` | Run identity; drives `.task(id:)` restarts. |
| `run()` | Consumes one stream. Call **only** from `.task(id: runID)`. |
| `refresh()` | The one restart verb — clears state, bumps the generation, restarts every observer. Use for retry buttons and parameter changes. |
| `patch { … }` | Ephemeral optimistic override of the current value. The next emission replaces it, so always pair it with a durable write. |
| `binding(_:)` | Two-way (writable key path, goes through `patch`) or read-only projection into the payload. |
| `FutureValue<Params, Result>` | One-shot: `execute(_:)` → `.initial/.loading/.success/.failure`, `reset()`. The designated write path. |
| `SideEffect<Input, Output>` | Injectable async operation; invoke as `.run(_:)` — never `callAsFunction`, which silently recurses against a same-named method. |

## Lifecycle

Appear → subscribe. Disappear → task cancelled, listener removed. Re-appear → new run,
**last value kept** (no loading flash), stale `.error` cleared to `.empty`. Stream ends
normally → last value kept. Stream throws → `.error`.
