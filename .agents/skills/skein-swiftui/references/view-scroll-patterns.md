# Scroll patterns

Recipes built on a scrolling container. The container choice, the modifier rules and the
pitfalls live in **view/scroll** — read that first; this file assumes them.

| Want | Pattern |
|---|---|
| Chat / log pinned to the newest message | [Pinned to bottom](#pinned-to-bottom) |
| Jump to top from a tab bar or toolbar | [Jump to an anchor](#jump-to-an-anchor) |
| Header that collapses as content rises | [Threshold chrome](#threshold-chrome) |
| Hero image that lags the scroll | [Stretchy hero](#stretchy-hero) |
| Cards that fade or shrink at the edges | [Per-item scroll transition](#per-item-scroll-transition) |
| Full-width pages, one swipe each | [Paging](#paging) |
| Horizontal carousel that lands on a card | [Snapping carousel](#snapping-carousel) |
| Load the next page near the end | [Pagination sentinel](#pagination-sentinel) |
| Section headers that stick while scrolling | [Pinned section headers](#pinned-section-headers) |
| Jump-to-section index or table of contents | [Two-way section sync](#two-way-section-sync) |
| Restore where the user was last time | [Restored position](#restored-position) |
| Detail screen whose second layer is revealed by scrolling | [Scroll reveal](#scroll-reveal) |
| Reading-progress bar | [Progress readout](#progress-readout) |

Two ideas recur and are worth stating once:

- **One `progress` value, many effects.** Derive a single normalized `CGFloat` from real
  scroll geometry and feed it to every offset, opacity, blur and scale. Parallel booleans
  (`isExpanded`, `isSnapped`, `isHeaderHidden`) drift out of sync; a derived value cannot.
- **Reduce before you store.** `contentOffset` changes every frame. If the feature only
  needs "past 50pt" or "which id is on screen", transform to that in the
  `onScrollGeometryChange` closure so the action — and the view update — fires once.

## Pinned to bottom

Declarative, no proxy and no sentinel view. `.sizeChanges` is what keeps it pinned as
messages arrive; `.alignment` alone only sets the initial position.

```swift
ScrollView {
    LazyVStack {
        ForEach(messages) { MessageRow(message: $0) }
    }
}
.defaultScrollAnchor(.bottom)                    // start at the newest
.defaultScrollAnchor(.bottom, for: .sizeChanges) // stay there as content grows
.scrollDismissesKeyboard(.interactively)
```

Growing content only holds the anchor while the user is already at the bottom, which is
the behaviour you want — a user reading history is not yanked away.

## Jump to an anchor

`ScrollPosition` is state, so any view that can reach it can move the scroll view. Prefer
it over `ScrollViewReader`, which only hands a proxy to its own subtree.

```swift
@State private var position = ScrollPosition()

ScrollView {
    LazyVStack { ForEach(items) { ItemRow(item: $0) } }
        .scrollTargetLayout()          // required to scroll to an id
}
.scrollPosition($position)
.toolbar {
    Button("Top") { withAnimation { position.scrollTo(edge: .top) } }
}
```

`scrollTo(edge:)` needs no id at all. Use `position.scrollTo(id:anchor:)` for a specific
item, and read `position.viewID(type: Item.ID.self)` for the topmost visible id.

## Threshold chrome

Show, hide or restyle chrome from a `Bool`, not from the offset. Add
`contentInsets.top` so the threshold is measured from the visible edge rather than from
the content origin.

```swift
@State private var isScrolled = false

ScrollView { content }
    .onScrollGeometryChange(for: Bool.self) { geometry in
        geometry.contentOffset.y + geometry.contentInsets.top > 50
    } action: { _, past in
        withAnimation(.snappy) { isScrolled = past }
    }
    .safeAreaBar(edge: .top) {
        if !isScrolled { FilterBar().transition(.move(edge: .top)) }
    }
```

Use `safeAreaInset` / `safeAreaBar` rather than an overlay: the bar reserves space, so the
first row is not hidden underneath it. On iOS 26 and macOS 26 the scroll edge effect
already separates content from a bar — hide chrome for room, not for legibility.

## Stretchy hero

`visualEffect` reads geometry without invalidating the view's layout, so it is the right
tool for continuous scroll-driven motion. `.scrollView` is the coordinate space to measure
in.

```swift
Image(.hero)
    .resizable()
    .scaledToFill()
    .frame(height: 280)
    .visualEffect { content, proxy in
        let minY = proxy.frame(in: .scrollView).minY
        return content
            .offset(y: minY > 0 ? -minY * 0.5 : 0)   // parallax when pulled down
            .scaleEffect(1 + max(0, minY) / 600, anchor: .bottom)
    }
    .clipped()
```

Overscroll only produces a positive `minY` when bouncing is enabled; pair with
`scrollBounceBehavior(.always)` if the page is too short to bounce on its own.

## Per-item scroll transition

For an effect keyed to *entering and leaving* the viewport, `scrollTransition` is simpler
and cheaper than measuring each item — it hands you a phase and interpolates for you.

```swift
ForEach(items) { item in
    ItemCard(item: item)
        .scrollTransition(.animated) { content, phase in
            content
                .opacity(phase.isIdentity ? 1 : 0.4)
                .scaleEffect(phase.isIdentity ? 1 : 0.92)
                .blur(radius: phase.isIdentity ? 0 : 4)
        }
}
```

`phase.value` is `-1` above, `0` centred, `1` below — use it for asymmetric motion. Reach
for `visualEffect` only when you need the raw frame.

## Paging

`containerRelativeFrame` sizes each page to the viewport without hardcoding a size, which
is what makes this work on both a phone and a resized Mac window.

```swift
ScrollView(.horizontal) {
    LazyHStack(spacing: 0) {
        ForEach(pages) { page in
            PageView(page: page)
                .containerRelativeFrame(.horizontal)
        }
    }
    .scrollTargetLayout()
}
.scrollTargetBehavior(.paging)
.scrollIndicators(.hidden)
```

Paging is a touch idiom. On macOS keep the same content but drop the paging behaviour, or
give the window explicit next/previous controls driven by `ScrollPosition` — a trackpad
user gets no page boundaries for free.

## Snapping carousel

```swift
ScrollView(.horizontal) {
    LazyHStack(spacing: 16) {
        ForEach(items) { ItemCard(item: $0).frame(width: 280) }
    }
    .scrollTargetLayout()
}
.scrollTargetBehavior(.viewAligned(limitBehavior: .alwaysByOne))
.contentMargins(.horizontal, 20, for: .scrollContent)
```

`limitBehavior: .alwaysByOne` makes one swipe advance one card, however hard the flick —
use it for a decision-carrying carousel, and the default for a browsing strip.
`contentMargins` insets the content while leaving the indicator at the container edge;
padding the stack instead would misplace the snap targets.

## Pagination sentinel

Visibility, not offset, is the signal — it survives varying row heights and a changing
content size.

```swift
LazyVStack {
    ForEach(items) { ItemRow(item: $0) }

    if store.hasMore {
        ProgressView()
            .onScrollVisibilityChange(threshold: 0.1) { visible in
                if visible { store.loadMore() }   // must be idempotent and re-entrant safe
            }
    }
}
```

The callback can fire more than once per approach, so guard the load in the store rather
than in the view. Never hang pagination off `contentOffset > contentSize - k`: it breaks
the moment content shrinks.

## Pinned section headers

```swift
ScrollView {
    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
        ForEach(groups) { group in
            Section {
                ForEach(group.items) { ItemRow(item: $0) }
            } header: {
                SectionHeader(group.title)
                    .background(.bar)     // a pinned header overlaps content; give it a ground
            }
        }
    }
}
```

`List` pins headers in its grouped-inset styles already; only build this for a custom
layout.

## Two-way section sync

An index or table of contents that both drives and follows the scroll view — one
`ScrollPosition` is both the write path and the read path, so the two can never disagree.

```swift
@State private var position = ScrollPosition()
@State private var visibleSection: Section.ID?

ScrollView {
    LazyVStack(pinnedViews: [.sectionHeaders]) { /* sections, each .id(section.id) */ }
        .scrollTargetLayout()
}
.scrollPosition($position)
.onScrollTargetVisibilityChange(idType: Section.ID.self) { ids in
    visibleSection = ids.first          // settled state, not a per-frame value
}
.safeAreaInset(edge: .trailing) {
    SectionIndex(sections: sections, current: visibleSection) { id in
        withAnimation { position.scrollTo(id: id, anchor: .top) }
    }
}
```

`onScrollTargetVisibilityChange` reports settled scroll targets, which is also the right
hook for haptics, analytics and accessibility announcements.

## Restored position

Persist the id, never the offset — an offset is meaningless after the content, the font
size or the window width changes.

```swift
@SceneStorage("feed.topItem") private var topItemID: String?
@State private var position = ScrollPosition()

ScrollView {
    LazyVStack { ForEach(items) { ItemRow(item: $0) } }
        .scrollTargetLayout()
}
.scrollPosition($position)
.onChange(of: position.viewID(type: String.self)) { _, id in
    topItemID = id
}
.task {
    if let topItemID { position.scrollTo(id: topItemID, anchor: .top) }
}
```

Use `@SceneStorage` for per-window continuity and `@AppStorage` only when the position is
genuinely global. Restore in `.task`, after the first layout, so the target exists.

## Scroll reveal

A detail screen with a primary surface and a secondary layer revealed by scrolling
instead of by a button — media detail that reveals actions, a map that becomes a form, a
viewer with an insights page. Paging between two sections, with every visual driven by one
measured `progress`.

```swift
private enum Layer: Hashable { case primary, secondary }

struct RevealDetail: View {
    @State private var position = ScrollPosition()
    @State private var progress: CGFloat = 0
    @State private var secondaryHeight: CGFloat = 1   // clamped: never divide by zero

    var body: some View {
        GeometryReader { container in
            ScrollView {
                VStack(spacing: 0) {
                    PrimaryLayer(progress: progress)
                        .frame(height: container.size.height)   // exactly one viewport
                        .id(Layer.primary)

                    SecondaryLayer(progress: progress)
                        .id(Layer.secondary)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                            secondaryHeight = max($0, 1)
                        }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollIndicators(.hidden)
            .scrollPosition($position)
            .onScrollGeometryChange(for: CGFloat.self) {
                $0.contentOffset.y + $0.contentInsets.top
            } action: { _, offset in
                progress = min(max(offset / secondaryHeight, 0), 1)
            }
            .safeAreaInset(edge: .bottom) {
                RevealAffordance(progress: progress) {
                    withAnimation(.smooth) {
                        position.scrollTo(id: progress < 0.5 ? Layer.secondary : Layer.primary,
                                          anchor: .top)
                    }
                }
            }
        }
    }
}
```

Keep:

- The primary layer exactly viewport-sized, so paging reads as switching between two
  states rather than as scrolling a document.
- `progress` measured against the real reveal distance. A hardcoded divisor breaks on the
  first dynamic-type change.
- A visible affordance — chevron or pill — while `progress` is near zero, faded out as the
  secondary layer takes over. Tapping it should snap, so the gesture is never mandatory.
- Hit testing off on overlays that fade out, or they keep swallowing taps at
  `opacity: 0`.

If a control appears to travel from the primary layer into the secondary one, do not
render two copies — publish a source and a destination anchor and interpolate a single
overlay between them with `progress`:

```swift
Color.clear.anchorPreference(key: ControlAnchor.self, value: .bounds) { ["source": $0] }
Color.clear.anchorPreference(key: ControlAnchor.self, value: .bounds) { ["destination": $0] }

.overlayPreferenceValue(ControlAnchor.self) { anchors in
    MorphingControl(anchors: anchors, progress: progress)
}
```

Two copies means two hit targets and two focus stops; one overlay keeps the motion
coherent.

## Progress readout

```swift
@State private var read: CGFloat = 0

ScrollView { ArticleBody() }
    .onScrollGeometryChange(for: CGFloat.self) { geometry in
        let span = geometry.contentSize.height - geometry.containerSize.height
        guard span > 0 else { return 0 }
        return min(max(geometry.contentOffset.y / span, 0), 1)
    } action: { _, value in
        read = value
    }
    .safeAreaInset(edge: .top, spacing: 0) {
        ProgressView(value: read)
            .progressViewStyle(.linear)
            .accessibilityHidden(true)    // decorative; VoiceOver tracks its own position
    }
```

Guard the divisor: a page shorter than its container gives a non-positive span, and
`0/0` propagates `NaN` through every effect downstream.

## Pattern-level pitfalls

- **A reveal or parallax must not be the only path to content.** Provide a tap, a button
  or a toolbar item that reaches the same state; scroll-only reveals are invisible to
  Switch Control and hard for limited dexterity.
- **Honour `accessibilityReduceMotion`.** Drop parallax, scale and blur to a cross-fade —
  read it from the environment and branch inside the effect, not around the layout.
- **One animation source per property.** If `progress` drives `offset`, no `withAnimation`
  may also drive it; the two interpolators fight and the result stutters.
- **Measure with `onGeometryChange`, not a `GeometryReader` background.** And clamp the
  measurement, or a zero height on the first pass feeds back into a layout loop.
- **Effects at the edges need `scrollClipDisabled()`** on the scroll view, or a scaled or
  shadowed card is cut off exactly where the effect is most visible.
