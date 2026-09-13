# Flow

One direction: **state → view → intent → state**. Covers dispatching, in-flight state,
optimistic updates, and rollback. Companion to **state/primitives** (the wrappers),
**state/injection** (where the model comes from), and **state/streams** (state fed by an
`AsyncSequence`).

## The loop

```
@Observable model  ──renders──▶  View  ──intent (method call)──▶  model method
        ▲                                                              │
        └──────────────── mutation on @MainActor ◀──── effect (async) ─┘
```

- Views **read** freely and **write** only through bindings they own (text fields,
  toggles) or an intent method. No `model.items.append(...)` from a button action.
- Intents are ordinary methods on the model — named for what the user did
  (`addToCart(_:)`, `retry()`), not for the mutation.
- Mutations happen on `@MainActor`, in the model. An effect may hop off-actor to do work,
  but the write back is a single main-actor statement.

### Methods or an `enum Action`?

Methods by default: they type-check arguments, allow `async`, and need no dispatch
plumbing. Introduce `enum Action` + `send(_:)` only when you need a *transcript* — event
logging, replay, undo stacks, or a state machine you want to test as a table. Even then
keep it one layer thick; a reducer wrapping a reducer is the MVVM tax in a new coat.

## One writer per piece of state

```swift
@MainActor @Observable
final class CartModel {
    private(set) var items: [CartItem] = []      // written only by this model
    private(set) var pending: Set<Item.ID> = []  // in-flight ids
    private(set) var failure: CartError?         // errors as state, not thrown at the view

    var total: Money { items.reduce(.zero) { $0 + $1.subtotal } }  // derived, never stored twice
}
```

- `private(set)` everything the view shouldn't write; expose intents instead.
- Derive rather than duplicate; cache a derived value as a stored property only when
  observation granularity demands it (see **state/primitives**).
- With streamed state, the stream is the only writer of the payload. Flow state
  (submitting, dismissing, a transient banner) lives in *separate* properties beside it —
  an emission would clobber it mid-flow.

## Intent → effect → state

```swift
func add(_ item: Item) async {
    guard !pending.contains(item.id) else { return }   // ignore double taps
    pending.insert(item.id)
    defer { pending.remove(item.id) }

    do    { items = try await client.addToCart(item) }
    catch is CancellationError { return }              // cancellation is not a failure
    catch { failure = .add(item.id, error) }
}
```

- Per-id `pending`, not one `isLoading` flag, whenever operations can overlap.
- Long work is driven by `.task` / `.task(id:)` from the view; the model stores no
  `Task`s and starts no free-running ones.
- Errors land in state and are cleared by the next attempt or an explicit dismissal;
  present with `.alert(item:)` / an inline error view bound to that property.

## Optimistic updates

Apply locally, call the server, reconcile.

```swift
func toggleFavorite(_ id: Item.ID) async {
    let snapshot = favorites                  // 1. snapshot the whole slice
    favorites.formSymmetricDifference([id])   // 2. apply optimistically

    do { try await client.setFavorite(id, favorites.contains(id)) }
    catch {
        favorites = snapshot                  // 3. roll back to the snapshot
        failure = .favorite(id, error)
    }
}
```

Rules:

- **Roll back to a snapshot, never by inverting the edit.** Inversion is wrong the moment
  anything else touched that slice while the call was in flight.
- **Only where the failure is rare and the undo is visually cheap** — likes, reorders,
  read flags, local renames. Never for payments, deletions, or anything with an external
  side effect: show progress and commit on success.
- **Tell the user when a rollback happens.** A silently reverted toggle reads as a bug.
- **Guard overlap.** Key in-flight work by id, or carry a generation counter and drop a
  response whose generation is stale:

```swift
generation &+= 1
let token = generation
let result = try await client.search(query)
guard token == generation else { return }     // a newer request already won
results = result
```

- **Streamed state uses `patch(_:)`** — an ephemeral local override replaced by the next
  emission, so it must always be paired with the durable write that causes that emission
  (see **state/streams**).

## Multi-step flows

Model the phases as one enum, not a handful of booleans:

```swift
enum CheckoutPhase: Equatable { case idle, confirming(Order), submitting, done(Receipt), failed(CheckoutError) }
```

- Illegal combinations stop being representable, and the view becomes an exhaustive
  `switch`.
- Keep the phase on the model, not scattered across `@State` flags in the view, when more
  than one view or effect reads it.
- Navigation driven by the flow (a sheet that opens on `.confirming`) binds to the phase
  rather than to a separate `isPresented` (see **navigation/modal**).

## Pitfalls

- A view mutating model properties directly — the write path disappears from the model
  and can't be tested or logged.
- Two writers for one property (a stream and a button handler) — emissions clobber the
  user's edit.
- Rollback by inverse operation instead of a snapshot.
- Optimism on destructive or paid actions.
- A single `isLoading` covering concurrent operations — the first completion clears it.
- Treating `CancellationError` as a user-facing failure.
- Booleans (`isEditing && isSaving && !isValid`) where one phase enum belongs.
