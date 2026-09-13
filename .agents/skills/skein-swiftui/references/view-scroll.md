# Scroll

Choosing and configuring a scrolling container. Companion to **view/lists** (row-shaped
data) and **view/layout** (sizing the content inside). Patterns live in
**view/scroll-patterns**; this file is only the decision and the rules.

## Pick a container

| Situation | Use |
|---|---|
| Rows of data — selection, swipe actions, sections, edit mode | `List` |
| Column-shaped data on macOS/iPadOS | `Table` |
| Custom or mixed layout, large or unknown item count | `ScrollView` + `LazyVStack` / `LazyHStack` / `LazyVGrid` |
| Custom layout, small fixed content | `ScrollView` + plain `VStack` / `HStack` |

`List` and `Table` already contain a scroll view — never wrap them in one. The scroll
modifiers below apply to their implicit scroll view just the same.

Lazy stacks are the exception, not the default: they defer construction but give up
knowing their own size, which breaks some layout and scroll-to behaviour. Reach for one
when the item count is large or unbounded.

## Rules

- **One scroll view per axis.** Nesting two vertical scroll views conflicts over the
  gesture and disagrees about content size. Nesting perpendicular axes is fine.
- **Drive position with state, not a proxy.** Use `scrollPosition(id:)` for
  "which item is at the top", or `scrollPosition(_:)` with a `ScrollPosition` binding
  for edge/offset control. `ScrollViewReader` + `ScrollViewProxy` remains correct only
  for imperative jumps to an id that is not part of your state.
- **Set the starting point declaratively.** `defaultScrollAnchor(.bottom)` beats
  scrolling to a sentinel view on appear — no layout pass, no animation to suppress.
- **Keep item identity stable.** Every scroll-to, snap and visibility callback is keyed
  by id; a regenerated id silently breaks all three and can jump the content.
- **Inset, don't pad.** Use `safeAreaInset(edge:)` — or `safeAreaBar(edge:)` for a
  control bar — so overlaid chrome reserves space in the scroll view's safe area.
  `contentMargins(_:for:)` insets content while leaving scroll indicators at the edge.
  Padding the content instead misplaces indicators, keyboard avoidance and scroll-to.
- **Observe scrolling with the scroll APIs.** `onScrollGeometryChange(for:of:)`,
  `onScrollPhaseChange(_:)` and `onScrollVisibilityChange(threshold:)` report offset,
  phase and visibility directly. A `GeometryReader` in a background measuring offsets is
  a workaround for an API that now exists.
- **Never write state on every frame.** Scroll callbacks fire continuously; map to a
  coarse value (a threshold crossed, an id, a `Bool`) and let SwiftUI dedupe.
- **Snapping is two modifiers.** `scrollTargetBehavior(.viewAligned)` or `.paging` on the
  scroll view, plus `scrollTargetLayout()` on the *stack inside it*. Only the behaviour
  is not enough.

## Platform notes

- On iOS 26 / macOS 26, content meeting a toolbar or bar gets a scroll edge effect
  automatically. Tune it with `scrollEdgeEffectStyle(_:for:)`; hide it with
  `scrollEdgeEffectHidden(_:for:)` only when the edge is genuinely opaque.
- Indicators are transient on iOS and persistent on macOS. Hide them with
  `scrollIndicators(.hidden)` only for short horizontal strips where the content itself
  signals there is more; a long list needs its indicator as a position cue.
- `scrollBounceBehavior(.basedOnSize)` stops a short page bouncing when it does not
  actually scroll.
- macOS and iPadOS also scroll from a pointer, trackpad and keyboard;
  `scrollInputBehavior(_:for:)` enables or disables a specific input kind.

## Pitfalls

- `scrollDisabled(true)` still keeps the scroll view's layout and clipping. To lay out
  content that never scrolls, use a plain stack.
- Effects drawn outside the content bounds (shadows, hover scale) are clipped; opt out
  with `scrollClipDisabled()` on the scroll view.
- A text field inside a scroll view needs `scrollDismissesKeyboard(_:)` — the default
  differs by container and is rarely what a custom layout wants.
- `scrollContentBackground(.hidden)` is what reveals a custom background behind a `List`
  or `Form`; setting `.background` on the rows will not.
