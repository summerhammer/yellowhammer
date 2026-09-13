# State Primitives

What a view *declares* and what an `@Observable` model *exposes*. Companion to
**state/injection** (how a model reaches the view) and **state/flow** (how it changes).

## Pick a wrapper

Check in order; first match wins.

| Declaration | Use when | Rule |
|---|---|---|
| `@State private var` | View owns the value or the `@Observable` instance | Always `private` |
| `@Binding var` | Child must **write** parent state | Never for read-only |
| `@Bindable var` | View receives an `@Observable` and needs bindings | Injected, not owned |
| `@Environment(Model.self) private var` | Shared `@Observable` from an ancestor | Inject per **state/injection** |
| `@Environment(\.key) private var` | Framework or custom environment value | Always `private` |
| `var` | Passed value the child reacts to via `.onChange(of:)` | Non-private |
| `let` | Read-only passed value | Default choice |

## @Observable models

```swift
@Observable
@MainActor
final class DataModel {
    var name = ""
}

struct MyView: View {
    @State private var model = DataModel()   // owned → @State, never `let`
}
```

- `@MainActor` on every `@Observable` class, unless the module sets default actor
  isolation to `MainActor`.
- Owning without `@State` lets SwiftUI recreate the instance on parent redraw, losing
  state. `@State` also gives bindings directly — no `@Bindable` needed.
- Nested `@Observable` objects are tracked; no flattening workaround needed.
- No `ObservableObject` / `@StateObject` / `@ObservedObject` / `@EnvironmentObject`, and
  no `ViewModel` layer — the `@Observable` class *is* the state.

### Property wrappers inside @Observable — require `@ObservationIgnored`

The macro rewrites stored properties; another wrapper's storage conflicts and fails to
compile.

```swift
@Observable @MainActor
final class SettingsModel {
    @ObservationIgnored @AppStorage("lastOpenedID") var lastOpenedID = ""
    var isLoading = false
}
```

Applies to `@AppStorage`, `@SceneStorage`, `@Query`, any wrapper. Never remove the
annotation; those wrappers notify SwiftUI through their own mechanisms, so views still
update.

### Make frequently-written property types `Equatable`

The generated setter skips invalidation when the new value equals the old — only if the
type is `Equatable`.

```swift
enum DeliveryStatus: Equatable { case placed, preparing, shipped, delivered }
```

Collections are `Equatable` only when their element is.

### Dependency granularity

Observation tracks reads per **property**, not per field:

- A computed property depends on everything its body reads (`currentItem` reading `items`
  → depends on the whole array).
- Reading `document.header.title` depends on all of `document.header`.
- Reading one element depends on the whole stored collection.

```swift
@MainActor @Observable
final class AppState {
    var items: [Item] = []      { didSet { recomputeCurrentItem() } }
    var currentID: Item.ID?     { didSet { recomputeCurrentItem() } }

    private(set) var currentItem: Item?
    private func recomputeCurrentItem() { currentItem = items.first { $0.id == currentID } }
}
```

Cache derived values as stored properties; expose the struct fields views actually read
as separate properties. When many rows each read several fields of their element, make
each element its own `@Observable` and have the parent persist the instances.

## Bindings

**Declare with `@Binding`, not `let x: Binding<T>`.** SwiftUI only subscribes to
`DynamicProperty` properties; an undecorated `Binding` value is never looked inside, so
external changes don't re-evaluate the view. Debug builds mask this with extra graph
passes — it often fails only in Release, worst in `UIViewRepresentable` /
`NSViewRepresentable`, where `updateUIView(_:context:)` then never runs.

**Prefer KeyPath/subscript bindings over `Binding(get:set:)`.** A closure binding
heap-allocates each `body` pass and can't be compared, causing extra invalidations.

```swift
// BAD
ScoreRow(score: Binding(get: { model[scoreFor: id] }, set: { model[scoreFor: id] = $0 }))

// GOOD
@Bindable var model = model
ScoreRow(score: $model[scoreFor: id])
```

Add a labeled subscript to the model if none fits. Reserve closure bindings for
transforms no key path can express.

A binding is the one sanctioned direct-write channel into a model (text fields, toggles).
Everything else goes through an intent method — see **state/flow**.

## Never pass values as @State

`@State` accepts only an initial value and ignores later parent updates — a passed
`@State var item: Item` shows the first value forever. Use `let`, or `@Binding` if the
child writes. Marking all owned state `private` keeps it out of the generated
initializer, preventing this by construction.

### Seeding owned state from a passed value

When the owned model needs the parent's data to be built, keep the passed value as `let`
and initialize the `@State` storage directly:

```swift
struct DocumentView: View {
    let document: Document

    @State private var editor: EditorModel

    init(document: Document) {
        self.document = document
        self._editor = State(wrappedValue: EditorModel(document: document))
    }
}
```

- Assign `_editor`, the storage — never `editor`.
- `init` runs on every parent update but only the first instance survives, so keep
  construction cheap and side-effect free.
- The seed is one-shot. To rebuild on a new value use `.id(document.id)`; to keep the
  model, feed it from `.onChange(of: document)`.
- Seeding from the **environment** needs the Shell / Content split — see
  **state/injection**.

## Custom environment values

Define custom values with `@Entry` — it replaces manual `EnvironmentKey` conformance and
also works with `Transaction`, `ContainerValues`, `FocusedValues`:

```swift
extension EnvironmentValues {
    @Entry var accentTheme: Theme = .default
}
ContentView().environment(\.accentTheme, customTheme)
```

**Never store a closure in a custom key.** Function values are uncomparable, so readers
invalidate on every environment write. Wrapping the closure in a struct does not help —
defunctionalize it:

```swift
struct SubmitAction { func callAsFunction(_ draft: String) { /* ... */ } }
extension EnvironmentValues { @Entry var submit = SubmitAction() }
```

Framework action types (`\.openURL`, `\.dismiss`, `\.refresh`) wrap closures by design
and are fine.

**Keep `@Entry` defaults stable.** The default expression is re-evaluated on every
fallback read, so `Model()`, `Date()`, `UUID()` invalidate readers on every unrelated
write. Back it with a `static let`, or make it optional and branch on `if let`:

```swift
extension EnvironmentValues {
    @Entry var model = _defaultModel
    private static let _defaultModel = Model()
}
```

**Remove unused `@Environment(\.key)` reads** — the declaration alone subscribes the
view. (The type form `@Environment(Model.self)` tracks per property and carries no such
cost.)

## Privacy

```swift
struct MyView: View {
    // owned → private
    @State private var isExpanded = false
    @State private var editor = EditorModel()
    @AppStorage("theme") private var theme = "light"
    @Environment(\.colorScheme) private var colorScheme

    // passed in → not private
    let title: String
    @Binding var isSelected: Bool
    @Bindable var settings: SettingsModel
}
```

`private` marks the boundary between what the view creates and what the generated
initializer accepts.

## Pitfalls

- A passed-in value declared `@State` — frozen at its first value forever.
- An `@Observable` owned as `let` — recreated on every parent redraw.
- A property wrapper inside `@Observable` without `@ObservationIgnored` — won't compile.
- `Binding(get:set:)` in a hot `body`, or an undecorated `let x: Binding<T>`.
- A closure or a fresh `Model()` as an environment default — invalidates every reader.
