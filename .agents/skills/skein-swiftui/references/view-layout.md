# Layout

Sizing and arranging views: stacks, grids, flow, safe areas, alignment. Companion to
**view/scroll** (the scrolling container), **view/lists** (row-shaped data),
**view/composition** (cutting the screen into view types) and **view/theming** (the
spacing and size tokens being applied).

## Pick a container

| Situation | Use |
|---|---|
| A few views in a line | `VStack` / `HStack` |
| Layered views, one sizing the group | `ZStack`, or `overlay` / `background` |
| Rows *and* columns that must align across rows | `Grid` + `GridRow` |
| Uniform cells, large or unbounded count | `ScrollView` + `LazyVGrid` / `LazyHGrid` |
| Same content, different arrangement per available space | `ViewThatFits` |
| Wrapping tags, chips, unequal-width runs | custom `Layout` |
| Fill the width, or align within it | `.frame(maxWidth: .infinity, alignment:)` |

`ZStack` sizes to its largest child and participates in layout; `overlay` / `background`
size to the *host* view and never change its size. Reach for the modifiers when one view
is clearly primary — that is most of the time.

`Grid` is eager and measures every cell, so it can align a column across rows;
`LazyVGrid` cannot, but scales to thousands of items. Choose on alignment vs. count.

## Sizing

- **Propose, don't dictate.** SwiftUI offers a size; the child picks one; the parent
  places it. Reading a device size (`UIScreen.main.bounds`) breaks in sheets, split view,
  Stage Manager and on macOS. A view should work as a screen, a sheet, a cell and a
  widget without knowing which it is.
- **`frame` is a *request*, and there are two of them.** `.frame(width:height:)` is a
  fixed proposal; `.frame(minWidth:idealWidth:maxWidth:)` is a range — prefer the range.
  `maxWidth: .infinity` means "take the offered width", not "take the screen".
- **Fill the width with `frame`, not `Spacer`.** `Text(…).frame(maxWidth: .infinity,
  alignment: .leading)` states the intent in one modifier; `HStack { Text(…); Spacer() }`
  adds a container for nothing. `Spacer` earns its place only *between* siblings.
- **Size relative to the container, not the screen.** `containerRelativeFrame(_:)`
  (optionally with a closure for a fraction) replaces the `GeometryReader` wrapper for
  page- and card-sized content, and keeps the view's own size intact.
- **Measure with `onGeometryChange(for:of:)`.** `GeometryReader` is a *container* that
  fills the offered space and proposes it to its child — dropping one in the middle of a
  hierarchy silently expands it. If you must read geometry, put it in a `.background` or
  `.overlay`, or use the modifier and skip the reader entirely.
- **Break a tie with `layoutPriority`, not with fixed widths.** Two `Text`s competing in
  one `HStack` split the space; `.layoutPriority(1)` on the one that must not truncate is
  the fix. `.fixedSize()` opts a view out of compression entirely — powerful and easy to
  overuse, because it can push a subtree past the screen edge.
- **Let `nil` spacing stay `nil`.** A stack's default spacing is platform- and
  content-aware; `spacing: 8` everywhere flattens that. Set a number when the design
  calls for a specific rhythm, then take it from a spacing token.

## Grids

`LazyVGrid`/`LazyHGrid` take `GridItem` tracks in the *cross* axis:

```swift
// Adaptive — as many columns as fit; the right default for galleries and pickers
LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) { … }

// Fixed count — when the column count is part of the design
LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3)) { … }
```

`.adaptive` is what makes one grid work on a phone, a split-view iPad and a resized Mac
window — prefer it to a size-class branch. Keep the `GridItem` spacing and the grid's own
`spacing` equal, or the gutters come out uneven in one axis. For square cells use
`.aspectRatio(1, contentMode: .fill)` on the cell content; a `GeometryReader` per cell
costs a layout pass each.

For an eager `Grid`, `gridCellColumns(_:)` spans tracks and
`gridColumnAlignment(_:)`/`gridCellAnchor(_:)` control placement. An empty `Color.clear`
cell is the idiomatic placeholder.

## Flow and adaptation

There is no built-in flow layout. Two answers, in order:

1. **`ViewThatFits`** — give it the arrangements, largest first, and it picks the first
   that fits the proposal. The canonical fix for a label row that must become a column at
   large Dynamic Type sizes (see **system/accessibility**).
2. **A custom `Layout`** — `sizeThatFits(proposal:subviews:cache:)` plus
   `placeSubviews(in:proposal:subviews:cache:)`. Worth it for genuine wrapping (tag
   clouds, chip rows); it is a single layout pass over `Subviews`, far cheaper than
   nesting stacks driven by measured widths. Use the `cache` for anything derived from
   `subviews`, and note that `AnyLayout` lets you swap two layouts with an animation.

Adapt on the *environment*, not on numbers: `\.horizontalSizeClass` (iOS/iPadOS),
`\.dynamicTypeSize`, `\.layoutDirection`. Use leading/trailing edges and
`.padding(.horizontal)` so RTL mirrors for free — `.left`/`.right` do not.

## Safe areas

- **`ignoresSafeArea` is for backgrounds only.** Extend a color, image or material to the
  edges; never controls or text. Scope it: `.ignoresSafeArea(.container, edges: .top)`.
- **Add chrome with `safeAreaInset(edge:)`** — or `safeAreaBar(edge:)` on iOS 26 / macOS
  26 for a control bar. Both *reserve* space, so scroll content, keyboard avoidance and
  scroll-to all account for it; an `overlay` does not and covers the last row. Details
  and worked bars in **view/scroll-patterns**.
- **Don't stack top insets.** A `safeAreaInset(.top)` plus a visible navigation bar
  background reads as two layers; hide one (`toolbarBackground(.hidden, for:
  .navigationBar)`) or use `safeAreaBar`, which integrates with the bar.
- **`safeAreaPadding(_:)` pads *by* the safe area** rather than consuming it — the right
  tool for content that must clear the home indicator without being inset twice.
- The keyboard is a safe-area region. `.ignoresSafeArea(.keyboard)` disables avoidance
  for a background; applying it to a form is what breaks the focused field scrolling into
  view.

## Alignment guides

A stack's `alignment:` argument aligns every child on one guide. When a child needs to
align differently, override its guide rather than nudging it with padding:

```swift
HStack(alignment: .firstTextBaseline) {
    Image(systemName: "star.fill")
        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
    Text("Featured")
}
```

To align views that are *not* siblings (a label in one row with a value in another),
declare a custom alignment:

```swift
extension HorizontalAlignment {
    private enum ValueColumn: AlignmentID {
        static func defaultValue(in d: ViewDimensions) -> CGFloat { d[.leading] }
    }
    static let valueColumn = HorizontalAlignment(ValueColumn.self)
}
```

Then use it as the enclosing stack's alignment and mark each participant with
`.alignmentGuide(.valueColumn) { … }`. Prefer `Grid` when the result is really a table —
it does this without the ceremony.

## Pitfalls

- **`GeometryReader` in a `VStack`** takes all the remaining height and its child
  collapses to the top-leading corner. Almost always the wrong tool now.
- **Nested `GeometryReader`s** re-propose sizes and can thrash the layout. One reader, or
  none.
- **Writing state from a size read** risks a feedback loop: the state changes the layout,
  which re-reads the size. Quantise the value (a threshold, a size class, an enum) before
  it lands in `@State`.
- **Deeply nested stacks** cost a layout pass per level and slow the type-checker; flatten
  and extract subviews — real `View` types, per **view/composition**.
- **Padding a scroll view's content instead of insetting it** misplaces indicators and
  keyboard avoidance — see **view/scroll**.
- **A `Spacer` inside a `List` row or a lazy stack** expands to the container's idea of
  infinity, not the row's; use `frame(maxWidth: .infinity)` instead.
- **Clipping a layered view without `.compositingGroup()`** antialiases each `overlay` /
  `background` layer separately, leaving colour fringes at rounded corners. Put
  `.compositingGroup()` before `.clipShape(_:)`.
- **`fixedSize()` on text inside a narrow parent** produces clipped or off-screen content
  rather than wrapping; pair it with an axis (`fixedSize(horizontal: false, vertical:
  true)`) when the goal is only "don't truncate vertically".
