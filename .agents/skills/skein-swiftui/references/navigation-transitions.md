# Transitions

Views entering and leaving — an `if` revealing a card, a push, a sheet — and keeping an
element continuous across the change. Companion to **view/animation** (views that stay
put and interpolate), `NavigationStack` and **navigation/modal** (the presentations
being transitioned).

## Pick a mechanism

| Situation | Use |
|---|---|
| A view appears or disappears in place | `.transition(_:)` |
| An element moves between two layouts in the same hierarchy | `matchedGeometryEffect` |
| A thumbnail expands into a pushed or presented screen | `matchedTransitionSource` + `.navigationTransition(.zoom(…))` |
| A push should cross-fade instead of slide | `.navigationTransition(.crossFade)` |
| Content swaps inside a fixed frame (text, a symbol, a number) | `.contentTransition(_:)` |

Reach for the cheapest one that fits. A matched transition that spans screens is far more
fragile than a `.transition` that does not, and looks wrong if the two views are not
genuinely the same object to the user.

## View transitions

A transition describes the view's appearance *outside* the tree; SwiftUI interpolates
between that and identity on insertion, and back on removal.

```swift
VStack {
    Button("Details") { showDetail.toggle() }
    if showDetail {
        DetailCard()
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
.animation(.snappy, value: showDetail)
```

- **The animation must live outside the condition.** A `.animation` attached inside the
  `if` is removed along with the view, so the removal never animates. Put it on a
  surviving ancestor, or drive the change with `withAnimation`.
- **Built-ins:** `.opacity` (the default), `.scale`, `.slide`, `.move(edge:)`,
  `.offset(…)`, `.push(from:)`, `.blurReplace` and `.identity`. Compose with
  `.combined(with:)`, and split direction with
  `.asymmetric(insertion:removal:)` — content that scales in should usually not scale out.
- **Pin an animation to the transition** with `.transition(.scale.animation(.bouncy))`
  when one element should move differently from everything else in the same change.
- **Identity drives transitions.** Two views in the branches of an `if`, or one view whose
  `.id` changed, are an insert plus a remove — that is a transition, not an animation, and
  `.animation(_:value:)` alone will do nothing.

### Custom transitions

Conform to `Transition` and read the `phase`. `TransitionPhase` is `.willAppear`,
`.identity` or `.didDisappear`; `phase.isIdentity` covers the common case, and
`phase.value` (`-1`, `0`, `1`) gives a signed number to multiply by.

```swift
struct Rise: Transition {
    func body(content: Content, phase: TransitionPhase) -> some View {
        content
            .opacity(phase.isIdentity ? 1 : 0)
            .offset(y: phase.isIdentity ? 0 : 24)
            .blur(radius: phase.isIdentity ? 0 : 8)
    }
}
```

A named transition is reusable and — unlike inline `showDetail ? … : …` modifiers —
actually animates on removal, because the view is already gone by the time the ternary
would be re-evaluated.

## Matched geometry, in one hierarchy

`matchedGeometryEffect(id:in:)` makes one view adopt another's frame during a change.
Both views must exist in the tree at the same moment, under a shared `@Namespace`.

```swift
@Namespace private var hero

if isExpanded {
    Card().matchedGeometryEffect(id: item.id, in: hero)
} else {
    Thumbnail().matchedGeometryEffect(id: item.id, in: hero)
}
```

- **Exactly one source per id at a time.** With two views present, mark one
  `isSource: false`. Two sources, or none, produce a jump.
- **Match `properties:` to intent.** `.frame` is both position and size; use
  `.position` alone when the destination should keep its own size.
- **Ids must be stable and unique within the namespace.** A `UUID()` created in `body`
  changes every update and silently disables the effect.
- It geometrically *ties two views together*; it does not morph one into the other. Very
  different content cross-fades while the frame animates, which reads well for
  thumbnail→card and badly for text→image.

## Matched transitions, across screens

For a push or a presentation, the two views are never in the tree together, so
`matchedGeometryEffect` cannot work. Mark the source, then declare the transition on the
destination.

```swift
@Namespace private var namespace

NavigationStack {
    Grid {
        ForEach(photos) { photo in
            NavigationLink(value: photo) {
                Thumbnail(photo: photo)
                    .matchedTransitionSource(id: photo.id, in: namespace)
            }
        }
    }
    .navigationDestination(for: Photo.self) { photo in
        PhotoDetail(photo: photo)
            .navigationTransition(.zoom(sourceID: photo.id, in: namespace))
    }
}
```

The same pair works for `.sheet` and `.fullScreenCover`: put `matchedTransitionSource` on
the control that presents, and `.navigationTransition(.zoom(sourceID:in:))` on the
presented root.

- **The ids must be equal on both sides**, and the namespace must be the same one. A
  destination built in a different view needs the `Namespace.ID` passed to it explicitly.
- **Shape the source** with
  `matchedTransitionSource(id:in:configuration:)` — `.clipShape`, `.background`,
  `.shadow` — so the zoom starts from the rounded rectangle the user sees rather than the
  view's square bounds.
- **`NavigationTransition` is a closed protocol.** `.automatic`, `.crossFade` and
  `.zoom(sourceID:in:)` are the whole set; you cannot write your own. A genuinely bespoke
  screen transition has to be built as an overlay or `fullScreenCover` with `.transition`
  and `matchedGeometryEffect`, and you own the interactivity yourself.
- **Toolbar items can be sources too** — `matchedTransitionSource` exists on
  `ToolbarContent`, which is how a "+" button grows into the sheet it opens.

## Interactive dismiss

- The zoom transition is **interactive in both directions**: the user can drag or pinch
  the pushed or presented screen back toward its source, and release to cancel. That is
  the payoff for wiring up the ids, and it is why the source must remain on screen.
- A sheet is swipe-dismissible by default. Disable it with
  `.interactiveDismissDisabled(true)` **only** when there is unsaved work, and always
  offer a visible Cancel — see **navigation/modal**.
- `.presentationDragIndicator(.visible)` is a hint, not a mechanism. It does not enable
  dismissal and is ignored on a full-screen cover.
- A `NavigationStack` push has an interactive back-swipe from the leading edge. Putting a
  horizontal `DragGesture` on the pushed view's root competes with it; scope the gesture to
  the element that needs it.
- **Observe dismissal, don't intercept it.** There is no "should dismiss" callback. Guard
  with `interactiveDismissDisabled` and run confirmation from your own Cancel action.

## Platform notes

- On iOS 26 / macOS 26 presentations morph out of the control that triggered them, so a
  sheet attached to the right button already looks connected before you add a zoom.
- macOS has no full-screen cover and no edge-swipe back. Zoom transitions are available,
  but window-based flows usually want a plain push or a separate window instead.
- Reduce Motion should collapse a zoom to a cross-fade — check
  `@Environment(\.accessibilityReduceMotion)` and substitute `.crossFade`.

## Pitfalls

- **A transition with no animation context is ignored**, silently: the view just appears.
- **`matchedGeometryEffect` across a sheet boundary does nothing.** The presented content
  is a separate hierarchy; use `matchedTransitionSource` + `.zoom`.
- **A zoom source inside a lazy container that has scrolled away** breaks the return leg —
  the transition falls back to a plain dismiss.
- **Nested `ForEach` reusing the same id in one namespace** picks an arbitrary source.
  Namespace the id by section, or use a composite value.
- **Transitions on the root of a `List` row** fight the list's own insert/remove
  animations. Animate the row's content, not the row.
- **`.transition` on a view inside a `ZStack` still animates opacity by default**, so a
  `.move` alone often looks like a fade — combine explicitly.
