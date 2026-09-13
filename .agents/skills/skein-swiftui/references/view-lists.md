# Lists

Row-shaped data: `List`, `Table`, lazy stacks and grids. Companion to **view/scroll**
(the scrolling container itself) and **view/layout** (sizing row content). Patterns live
in **view/lists-patterns**; this file is the decision and the rules.

## Pick a container

| Situation | Use |
|---|---|
| Rows with selection, swipe actions, sections, edit mode, separators | `List` |
| Rows backed by a `ForEach` over model data | `List` + `ForEach` |
| Column-shaped, sortable data — macOS and regular-width iPadOS | `Table` |
| Uniform items in columns — galleries, pickers, tiles | `ScrollView` + `LazyVGrid` |
| Custom or mixed row layout, large or unbounded count | `ScrollView` + `LazyVStack` |
| Custom layout, small fixed content | `ScrollView` + plain `VStack` |

`List` is the default for anything row-shaped. It gives you row reuse, accessibility
semantics, selection, swipe actions, edit mode and separators for free — all of which you
would otherwise rebuild by hand on a `LazyVStack`. Drop to a lazy stack when a row's
layout fights `List`'s row container, not merely because the rows look custom.

`List` and `Table` already contain a scroll view — never wrap them in one, and never nest
a `ScrollView` in a row.

## Identity is the whole game

Every row animation, scroll-to, selection and swipe is keyed by id. Unstable identity does
not fail loudly; it shows up as broken animations, lost focus mid-edit, duplicate rows and
a diff cost that scales with the collection.

- **Never identify by position.** `ForEach(items.indices, id: \.self)` and
  `ForEach(items.enumerated(), id: \.offset)` make the id the *slot*, not the element —
  inserts and reorders reset row state, and index access can crash on removal. Use
  `ForEach(items)` for `Identifiable`, or `id: \.element.id` when you need the index as
  data.
- **The id must outlive the row and survive edits.** `var id: String { title }` changes
  the moment the user types; SwiftUI reads that as delete-plus-insert and the text field
  loses focus. Use a stored `let id: UUID` or a server key.
- **Never synthesize ids in `body`.** `ForEach(items.map { Item(title: $0) })` mints fresh
  `UUID`s on every body pass, so the whole list reads as replaced every update. Build
  identity in the model layer.
- **Ids must be genuinely unique.** Two articles sharing a URL-derived id render as one
  row. A class's default `ObjectIdentifier` id is unique only for the object's lifetime
  and can be recycled.
- **Keep ids cheap to hash.** `id: \.self` on a large struct walks every field on every
  diff. Hash a small primitive and pass the whole element to the row.

## Keep rows unary

`List` and the lazy containers want every row's identity *up front*. When a row body
produces exactly one top-level view, SwiftUI templates the id from the element and never
runs the body. A top-level `switch`, a top-level `if` without `else`, or an `AnyView`
makes structural identity vary per row, so SwiftUI evaluates every row's body just to
compute ids — a cost that scales with the collection.

```swift
// Multi-view row: the body runs for every element, on screen or not
ForEach(items) { item in
    if item.isSpecial { SpecialRow(item: item) } else { RegularRow(item: item) }
}

// Unary row: one top-level container, branch inside it
ForEach(items) { item in
    ItemRow(item: item)
}

struct ItemRow: View {
    let item: Item
    var body: some View {
        VStack {                                    // single root keeps the row unary
            if item.isSpecial { SpecialRow(item: item) } else { RegularRow(item: item) }
        }
    }
}
```

If some elements should not be rows at all, filter the collection *before* the `ForEach` —
a zero-view row is the same problem. Launch with `-LogForEachSlowPath YES` to have SwiftUI
log every `ForEach` in a lazy container whose row builder is non-constant.

Filter and sort in the model, not inline: `ForEach(items.filter { $0.isEnabled })` rebuilds
the array on every body pass, so identity churns even when nothing changed.

## Lazy containers

`LazyVStack`, `LazyHStack`, `LazyVGrid` and `LazyHGrid` build a subview only as it nears
the viewport. That is the point — and the cost: a lazy stack does not know its own size,
which breaks some layout and scroll-to behaviour, and it never *releases* views it has
built. Use one when the item count is large or unbounded and the row views are non-trivial;
use a plain stack for small fixed content.

Grids take `GridItem` tracks — column sizing, spacing and cell spanning live in
**view/layout**.

## Styles and row chrome

| Style | Use |
|---|---|
| `.plain` | Feeds and timelines. Pins section headers on iOS. |
| `.insetGrouped` | Settings and forms on iOS — the platform default look. |
| `.grouped` | Multi-section discovery pages where the grouping is the structure. |
| `.inset` | macOS lists inside a pane. |
| `.sidebar` | The source list of a `NavigationSplitView`. |
| `.bordered` | macOS lists that need a visible container edge. |

Row-level modifiers go on the row content, not on the `List`:

- `listRowInsets(_:)` — the row's own padding; `.padding()` inside the row leaves the
  separator at the old inset.
- `listRowSeparator(.hidden)` and `listRowSeparatorTint(_:)` — per-row; use
  `listSectionSeparator(_:)` for the section's outer rules.
- `listRowBackground(_:)` — the row's background *including* its insets and selection
  behaviour. `.background()` inside the row paints only the content.
- `listRowSpacing(_:)` and `listSectionSpacing(_:)` on the `List` for vertical rhythm.
- `contentShape(.rect)` on rows that must be tappable across their full width.
- `.environment(\.defaultMinListRowHeight, 1)` when a dense row is being padded to the
  standard minimum.

A custom `List` background needs `scrollContentBackground(.hidden)` first — otherwise the
system background paints over yours.

## Sections and pinning

```swift
List {
    Section("General") { … }
    Section { … } header: { Text("Account") } footer: { Text("Signed in as …") }
}
```

`.plain` pins section headers to the top edge as you scroll; the grouped styles scroll
headers away with their content. If you need pinned headers in a custom layout, that is a
lazy-stack job — `LazyVStack(pinnedViews: [.sectionHeaders])`, covered in
**view/scroll-patterns**. A pinned header floats over content, so give it an opaque ground
(`.background(.bar)`).

## Selection and edit mode

`List(selection:)` takes a binding to an optional `ID` for single selection or a `Set<ID>`
for multiple. Selection only renders in edit mode on iOS; on macOS it is always live.

```swift
@State private var selection = Set<Item.ID>()

List(items, selection: $selection) { ItemRow(item: $0) }
    .toolbar { EditButton() }          // iOS; macOS selects without an edit mode
```

`selectionDisabled(_:)` opts individual rows out. Read or drive the mode yourself with
`@Environment(\.editMode)` when a custom control replaces `EditButton`.

## Swipe actions

```swift
MessageRow(message: message)
    .swipeActions(edge: .leading, allowsFullSwipe: false) {
        Button { store.toggleUnread(message) } label: { Label("Unread", systemImage: "envelope.badge") }
            .tint(.blue)
    }
    .swipeActions(edge: .trailing) {
        Button(role: .destructive) { store.delete(message) } label: { Label("Delete", systemImage: "trash") }
        Button { store.flag(message) } label: { Label("Flag", systemImage: "flag") }
            .tint(.orange)
    }
```

- Actions appear in the order written, starting from the swiping edge.
- A full swipe fires the first action for that edge. Turn it off with
  `allowsFullSwipe: false` for anything the user cannot undo.
- Defining *any* `swipeActions` suppresses the Delete that `onDelete(perform:)` would
  synthesize — you now own that button.
- Swipe is a touch idiom and is invisible to a pointer, a keyboard and VoiceOver's default
  gestures. Anything reachable only by swipe also needs a context menu entry or a toolbar
  action. `Button(role: .destructive)` and `Label` are what give the action its colour and
  its accessibility name; SwiftUI applies the `.fill` symbol variant for you.

## Reordering and deletion

`onMove` and `onDelete` attach to the `ForEach`, not the `List`:

```swift
List {
    ForEach(items) { ItemRow(item: $0) }
        .onMove { items.move(fromOffsets: $0, toOffset: $1) }
        .onDelete { items.remove(atOffsets: $0) }
}
.toolbar { EditButton() }
```

- The offsets are into the `ForEach`'s collection. With multiple `ForEach`s or a filtered
  view of the model, map them back yourself — the offsets are not model indices.
- `moveDisabled(_:)` and `deleteDisabled(_:)` pin or protect individual rows.
- Reordering needs edit mode on iOS; macOS drags rows directly. On iOS the drag handle
  only appears in edit mode, so a reorderable list needs an `EditButton` or an equivalent.
- Sort order that must persist belongs in the model as an explicit field, written in the
  `onMove` closure. A derived sort re-applies itself and undoes the drag.

## Pitfalls

- **Heavy layout inside a `List` row.** `List` measures rows eagerly in some styles; a row
  with its own nested stacks of expensive content is better served by
  `ScrollView` + `LazyVStack`.
- **A `ScrollView` inside a row.** The gestures conflict and neither container agrees about
  the content size.
- **`.background()` where `listRowBackground` was meant.** The former stops at the content
  edge; selection and separators still draw the system background around it.
- **A lazy stack for a short list.** You pay the deferred-sizing tax and gain nothing.
- **`AnyView` in a row.** It erases structural identity, which is exactly what the row
  templating depends on.
- **`Table` does not sort itself.** A `sortOrder` binding reports the user's intent; you
  re-sort the collection in `onChange(of: sortOrder)`.
- **`Table` collapses to one column in compact widths.** Design the first column to carry
  the combined information rather than letting the rest silently disappear.
