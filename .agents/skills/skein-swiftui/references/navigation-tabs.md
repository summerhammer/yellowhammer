# Tabs

Top-level sections a user switches between. Companion to **navigation/split** (the
wide-screen alternative root) and `NavigationStack` (pushing *inside* a tab).

## Pick a root

| Situation | Use |
|---|---|
| 3–5 peer sections, none derived from a selection | `TabView` |
| The same sections, but a sidebar on iPad/Mac | `TabView` + `.tabViewStyle(.sidebarAdaptable)` |
| Columns derived from a selection — list → detail | `NavigationSplitView` |
| Swipeable pages, not sections | `.tabViewStyle(.page)` |

## Rules

- **Use the `Tab` builder, never `.tabItem`.** `Tab("Home", systemImage: "house") { … }`
  is the current API; `.tabItem` is legacy and cannot express roles or sections. Mixing
  the two in one `TabView` fails to compile once any tab uses `Tab(role:)`.
- **Selection is an enum, not an `Int` or `String`.** Declare a `Hashable` enum of the
  sections and bind it:

  ```swift
  enum Section: Hashable { case home, search, profile }
  @State private var selection: Section = .home

  TabView(selection: $selection) {
      Tab("Home", systemImage: "house", value: .home) { HomeView() }
      Tab("Profile", systemImage: "person", value: .profile) { ProfileView() }
      Tab(role: .search) { SearchView() }
  }
  ```

  `value: 0` or `value: "home"` compiles and then rots: reordering tabs silently
  reassigns indices, and a typo'd string matches nothing with no error. The enum makes
  the set of tabs exhaustive, switchable, and safe to persist.
- **Every tab gets its own `NavigationStack`**, inside the `Tab` closure. One stack
  wrapped *around* the `TabView` is wrong — the tab bar would push away with the content.
- **`Tab(role: .search)` for search**, not a hand-built tab labelled "Search". It
  separates from the other tabs and morphs into a search field when selected.
- **Persist selection with `@SceneStorage`**, not `@State`, when the app should reopen on
  the tab the user left — and make the enum `RawRepresentable` by `String`, so an added or
  removed case degrades to the default instead of restoring the wrong tab.
- **Re-selecting the current tab should pop to root.** Drive it from a custom `Binding`
  whose setter compares to the old value, or from `.onChange`, and reset that tab's
  `NavigationPath`. Users expect it; nothing gives it to you for free.
- **Group related tabs with `TabSection`** in a sidebar-adaptable `TabView`. Sections
  render as sidebar groups on wide screens and collapse into the compact tab bar.
- **Let users reorder with `TabViewCustomization`**, stored in `@AppStorage`. Give every
  customizable tab a stable `.customizationID`; tabs without one are not customizable.

## Platform notes

- On iOS 26 / macOS 26 the tab bar is Liquid Glass floating over content. Don't put a
  background behind it; use `.backgroundExtensionEffect()` on content that should bleed
  beneath.
- **`.tabBarMinimizeBehavior(.onScrollDown)`** shrinks the bar as the user scrolls — the
  right default for a content-first screen, wrong for one the user tabs between constantly.
- **`.tabViewBottomAccessory { … }`** adds a persistent control strip above the bar (a now
  playing bar, a call banner). Read `\.tabViewBottomAccessoryPlacement` from the
  environment and shed detail when it collapses into the bar.
- macOS has no tab bar: `.sidebarAdaptable` renders a sidebar, plain `TabView` renders a
  segmented control. Pick deliberately — a five-section Mac app wants the sidebar.
- iPadOS 26 shows the floating tab bar at the top and can slide into the sidebar; both
  come from the same `.sidebarAdaptable` declaration.

## Pitfalls

- A `selection` binding whose type differs from the tabs' `value` type (`Section?` vs
  `Section`) compiles and never matches — no tab is ever selected.
- Tabs are lazy but *retained*: a tab's state survives switching away, so a view that
  polls or observes keeps working off screen. Stop the work in `.onDisappear`, or gate it
  on `selection`.
- More than five tabs on iPhone collapses the overflow into "More". If the app has more
  sections than that, it wants a sidebar, not a longer tab bar.
- Deep-linking must set `selection` *and* the target tab's path in the same update, or the
  push animates on a tab the user cannot see yet.
- `.badge` on a `Tab` takes an `Int` or `String`; passing `0` shows nothing, which is the
  behaviour you want — do not branch around it.
