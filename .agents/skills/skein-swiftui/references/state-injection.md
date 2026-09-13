# Injection

How a model or service reaches the view that uses it: a composition root, constructor
injection, the environment for app-lifetime values, and manual scoping. Companion to
**state/primitives** (declaring the wrappers) and **state/flow** (mutating what arrives).

## Two lanes — pick by lifetime

| Kind of dependency | Delivery | Why |
|---|---|---|
| App-lifetime services and shared models — session, API clients, account, theme | `.environment(...)` once at each scene root | One instance, readable anywhere, no prop drilling |
| Per-screen / per-feature state — a screen's store, an editor, a form controller | Constructor parameter → `@State` in the screen | Each screen instance stays independently scoped and dies with the view |

Never the reverse. A feature store in the environment is silently shared by two instances
of the same screen (two windows, two tabs, a push of the same screen onto a stack); an
app-wide service passed down by hand becomes a chain of unused parameters.

## Composition root

One place builds the object graph; nothing else calls a concrete initializer.

```swift
// Dependencies are narrow protocols, one per capability.
protocol UserReading:  Sendable { func user(id: User.ID) async throws -> User }
protocol UserStorage:  Sendable { func save(_ user: User) async throws }

// The container is a plain struct of dependencies — no framework, no resolver.
struct AppContainer {
    let users: any UserReading & UserStorage
    let session: Session          // @Observable, @MainActor
}

// Concrete wiring lives in ONE extension file: AppContainer+Live.swift
extension AppContainer {
    @MainActor static let live = AppContainer(users: FirebaseUserService(), session: Session())
}
```

```swift
@main
struct MyApp: App {
    @State private var container = AppContainer.live      // built once, @State not `let`

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(container.session)           // type-keyed: @Observable models
                .environment(\.users, container.users)    // key-keyed: protocol services
        }
    }
}
```

- Narrow protocols per capability, composed through an initializer. No property-wrapper
  injection, no service locator, no global `.shared` reached from a view.
- Keep the pure model decoupled from adapters: `<Type>+<Backend>.swift` holds the real
  wiring, the model file holds none.
- `@State` on the container in `App`: the `App` struct itself can be re-created.

## Inject at every scene root

Scenes do **not** inherit each other's environment. A second `WindowGroup`, `Settings`,
`MenuBarExtra`, a document scene, a widget, an App Intent, or an app extension each start
from an empty custom environment — a `@Environment(Session.self)` read there traps at
runtime.

```swift
var body: some Scene {
    WindowGroup { RootView().environment(container.session) }
    Settings    { SettingsView().environment(container.session) }   // repeat, don't assume
}
```

Sheets, popovers, `fullScreenCover`, and `NavigationStack` destinations *do* inherit the
presenting view's environment. UIKit/AppKit hosting boundaries do not — re-apply the
modifiers on each `UIHostingController` root. Extensions have their own process and graph
entirely (see **system/extensions**).

## Reading it back

```swift
@Environment(Session.self) private var session       // traps if never injected
@Environment(Session.self) private var session: Session?   // optional read, no trap
@Environment(\.users) private var users
```

Use the optional form for a dependency that is genuinely absent in some scene (previews,
an extension, a logged-out root). Elsewhere prefer the trapping form — a missing
injection should fail loudly on the first run, not silently render an empty screen.

Need bindings into an injected model? `@Bindable var session = session` locally, or
declare `@Bindable var` when it's passed as a parameter.

## Manual scoping

Scope is expressed by *where you construct*, not by a container API.

- **Feature scope** — construct the store in the screen that owns it and hold it as
  `@State`; it is created with the screen and released with it.
- **Subtree scope** — inject a narrower model for part of the hierarchy:
  `ChapterView().environment(chapterModel)`. The nearest injection wins.
- **Re-scope on identity** — `.id(document.id)` on the owning view rebuilds the state
  when the subject changes.

### Seeding owned state from the environment — Shell / Content

`@Environment` is not populated until `body` runs, so it cannot be read in `init`. Split
the view: a **Shell** that reads the environment and owns nothing, and a **Content** that
takes the value as `let` and seeds its own state.

```swift
struct DocumentScreen: View {                    // Shell — stateless
    @Environment(Session.self) private var session

    var body: some View { DocumentContent(session: session) }
}

private struct DocumentContent: View {           // Content — owns the state
    let session: Session

    @State private var editor: EditorModel

    init(session: Session) {
        self.session = session
        self._editor = State(wrappedValue: EditorModel(session: session))
    }

    var body: some View { /* ... */ }
}
```

- Name the pair `<Feature>Screen` / `<Feature>Content` (or `…Sheet`, `…Modal`); keep
  Content `private`.
- The Shell reads the environment and nothing else: no `@State`, no logic.
- Needed at presentation boundaries (screens, sheets, modals), where the environment
  first becomes available.
- The seed is one-shot; to rebuild, apply `.id(...)` to Content in the Shell's body.

## Keep views non-generic

Pass `any Capability` or a concrete adapter. Making a view generic over its dependency
(`struct ProfileView<S: UserReading>: View`) multiplies type identity, breaks
`.environment`-based defaults, and taxes the type checker for no testing benefit —
protocol existentials already allow substitution.

## Previews and tests

Give the container a second wiring and inject it the same way.

```swift
extension AppContainer {
    @MainActor static let preview = AppContainer(users: InMemoryUserService.populated, session: .demo)
}

#Preview {
    DocumentScreen()
        .environment(AppContainer.preview.session)
}
```

Keep mock factories in a `DevSupport/` folder so preview data never ships in release
paths. Tests construct the store directly with fakes — no environment, no view needed.

## Pitfalls

- `.environment(Model())` written inside a `body` — a fresh instance every render, state
  lost on each update. Construct where it's owned.
- A per-screen store injected through the environment — two instances of the screen share
  one state.
- Static singletons (`Service.shared`) read straight from a view — invisible dependency,
  untestable, and impossible to scope per window.
- Forgetting a scene root — crash only in the second window, `Settings`, or a widget.
- Reading `@Environment` in `init` — it's empty there; use Shell / Content.
- A framework-style resolver (`@Inject var`) — it defeats compile-time checking that the
  initializer gives for free.
