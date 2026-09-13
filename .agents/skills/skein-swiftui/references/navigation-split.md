# Split

Sidebar-plus-detail layouts on iPad and Mac. Companion to `NavigationStack` (pushing
*inside* a column) and **navigation/tabs** (the compact-width alternative root).

## Pick a root

| Situation | Use |
|---|---|
| Columns are derived from a selection — list → detail | `NavigationSplitView` |
| Top-level sections users switch between, sidebar only on wide screens | `TabView` + `.tabViewStyle(.sidebarAdaptable)` |
| A trailing utility panel over existing content (info, filters) | `.inspector`, not a third column |
| A persistent column *independent of selection* | manual `HStack` — see below |

## Rules

- **Selection is the API.** Bind `List(selection:)` in the sidebar; the trailing columns
  read that state. Never drive a split view with `NavigationLink(destination:)` in the
  sidebar — value-based links plus selection is the only coherent model.
- **Three columns means two selections.** Sidebar selection feeds `content:`, content
  selection feeds `detail:`. If the third column does not depend on the second, you do not
  want three columns.
- **Every column handles its empty state.** `detail:` renders before any selection exists;
  give it a `ContentUnavailableView`, not a blank `Text("Select an item")` afterthought.
- **Wrap `detail:` in its own `NavigationStack`** when it pushes. Each column is a separate
  hierarchy with its own `navigationDestination`.
- **Persist column visibility with `@SceneStorage`**, not `@State` — `NavigationSplitViewVisibility`
  should survive a scene restore, and iPad supports multiple windows with different layouts.
- **Use `preferredCompactColumn:`** when the collapsed stack should start somewhere other
  than SwiftUI's guess (e.g. straight into `.detail` after a deep link).
- **Size columns with `.navigationSplitViewColumnWidth(min:ideal:max:)`**, applied to the
  column's own content. Never `.frame(width:)` — it fights the divider and breaks the
  user's drag-to-resize.
- **`.navigationSplitViewStyle(.balanced)`** when the sidebar stays visible alongside the
  detail; `.prominentDetail` when the detail is the content (media, editor) and the sidebar
  should overlay. The default is `.automatic`.

## Manual `HStack` columns

Occasionally a "column" is not a navigation destination at all — a permanent notifications
or activity rail, a chat roster next to a canvas. Building it as `HStack { primary;
Divider(); secondary }`, gated on `horizontalSizeClass == .regular`, is legitimate:

```swift
HStack(spacing: 0) {
    TabView { /* primary */ }
    if horizontalSizeClass == .regular, showSecondary {
        Divider().ignoresSafeArea()
        NotificationsView()
            .environment(\.isSecondaryColumn, true)
            .frame(maxWidth: 420)
    }
}
```

**Prefer it only when all of these hold:** the second column's content is independent of
any selection, it must stay on screen while the primary navigates, and each column needs
its own toolbar or root (a `TabView` on the left, a stack on the right). Inject an
environment flag such as `isSecondaryColumn` so shared child views can shed chrome, and cap
the width so the layout does not thrash on resize.

**What you give up, and must rebuild:** the sidebar toggle toolbar item, drag-to-resize,
column visibility animation and restoration, automatic compact collapse, and the system
sidebar material. That is a lot of platform behaviour to reimplement — reach for it for a
genuinely non-standard rail, never merely to avoid learning the selection model.

## Platform notes

- On macOS the sidebar is resizable and its width is remembered by the system; hard-coding
  it is a visible regression. `Section` headers in a sidebar `List` are expected, not
  decorative.
- On iOS/iPadOS 26 the sidebar renders as Liquid Glass floating over the detail. Let it —
  do not set a `.background` on the sidebar, and use `.backgroundExtensionEffect()` on
  detail content that should bleed beneath it.
- iPad Slide Over and Stage Manager change size class at runtime: the split view collapses
  and re-expands live. Anything you build manually must survive that transition too.
- `.toolbar(removing: .sidebarToggle)` drops the automatic toggle when you supply your own.

## Pitfalls

- Selection of type `Item` rather than `Item.ID` compiles and silently never matches. Match
  the `List` row's identity.
- `columnVisibility` is ignored while collapsed; do not fight it with `onChange`.
- Putting one `NavigationStack` *around* the whole `NavigationSplitView` breaks both. The
  split view is the root.
- A sidebar `List` without `selection:` still looks right on iPad and does nothing on Mac —
  this is the most common cause of "detail never updates".
