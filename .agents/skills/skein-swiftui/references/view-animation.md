# Animation

Animating a view that stays in the tree while its values change. Companion to
**navigation/transitions** (views entering and leaving, and cross-screen continuity) and
**view/effects** (the effects being animated). Machinery you reach for less often —
transactions, phase and keyframe animators, custom `Animatable` types — lives in
**view/animation-advanced**.

## Animation or transition?

| The view… | Use |
|---|---|
| Exists before and after the change, with different values | an animation (this file) |
| Is inserted or removed by an `if`, a `ForEach` or a changed `.id` | a transition |
| Is replaced by a different view on another screen | a matched transition |

The distinction is identity, not appearance. A `Rectangle` whose `frame` changes is one
view interpolating; two `Rectangle`s in the branches of an `if` are an insertion and a
removal, and `.animation` will never smooth them — only `.transition` will.

## Pick a trigger

| Situation | Use |
|---|---|
| A specific value changes, anywhere it changes | `.animation(_:value:)` |
| Only some modifiers on a view should animate | `.animation(_:body:)` |
| An event — a tap, a gesture end, a callback | `withAnimation` |
| Only one property of a struct drives the motion | `@Animatable` / `animatableData` |

## Rules

- **Always pass the value.** `.animation(_:value:)` animates only when *that* value
  changes. The single-argument `.animation(_:)` is deprecated: it animates every change
  reaching the view, including ones from a parent you don't control.
- **Position matters.** The modifier animates what is *above* it in the chain. Put it
  after the modifiers it should cover, and stop the chain there — a second
  `.animation(nil, value:)` further up excludes the rest.
- **Scope narrowly.** `.animation` on the outermost container animates everything inside
  it, including subviews that happened to change for unrelated reasons. Attach it to the
  smallest view that actually moves.
- **`withAnimation` wraps the mutation, not the view.** Everything the state change
  touches this render pass animates, however far away. Keep the closure to the one
  assignment; do not do I/O or awaits inside it.
- **One source of truth per motion.** Derive every offset, scale and opacity from a single
  value. Parallel booleans (`isOpen`, `isBig`, `didSettle`) drift apart mid-flight and
  produce motion no one designed.
- **Animate transforms, not layout.** `scaleEffect`, `offset`, `rotationEffect`, `opacity`
  and `blur` are applied at draw time. Animating `frame`, `padding` or a stack's spacing
  re-runs layout every frame and can invalidate a lazy container's item sizes.
- **Never animate on every frame of an input.** Scroll offsets, drag translations and
  timers fire continuously. Map to a coarse value — a crossed threshold, an id, a `Bool` —
  and animate that. A `withAnimation` inside a per-frame callback stacks hundreds of
  overlapping animations.
- **Springs are the default.** `.smooth`, `.snappy`, `.bouncy` are the named springs; tune
  with `.spring(duration:bounce:)`. Reserve `.easeInOut` for pure appearance changes and
  `.linear` for genuinely linear progress. Duration curves make interactive UI feel dead
  because they cannot be interrupted gracefully.
- **Honour Reduce Motion.** Read `@Environment(\.accessibilityReduceMotion)` and swap
  large positional motion for a cross-fade. See **system/accessibility**.

## Springs

A spring is described by `duration` (roughly the time to settle) and `bounce`
(`0` critically damped, `>0` overshoots, `<0` sluggish). Prefer these over
`response`/`dampingFraction`, which express the same thing in less legible units.

```swift
.animation(.spring(duration: 0.4, bounce: 0.2), value: isExpanded)
```

Springs are **additive and interruptible**: a new one retargets from the current velocity
rather than restarting. This is why a spring-driven control still feels right when tapped
mid-animation, and why a `.easeInOut(duration:)` in the same place stutters.

`.smooth` for content settling, `.snappy` for controls responding to touch, `.bouncy` for
playful feedback. All three take an optional `duration:` and `extraBounce:`.

## Adjusting an animation

`.speed(_:)`, `.delay(_:)` and `.repeatCount(_:autoreverses:)` / `.repeatForever()` return
a modified animation, so they compose: `.spring.speed(1.5).delay(0.1)`. A
`repeatForever` animation never completes — it will keep a view dirty, so attach it only
while the view is visible and drive it from state you can turn off.

## Scoping with `animation(_:body:)`

Applies an animation to just the modifiers built inside the closure, leaving the rest of
the view unanimated. Clearer than alternating `.animation(_:value:)` and
`.animation(nil, value:)` up a chain.

```swift
Rectangle()
    .foregroundStyle(isActive ? .blue : .red)   // snaps
    .animation(.snappy) {
        $0.scaleEffect(isActive ? 1.2 : 1.0)    // animates
    }
```

## Platform notes

- On iOS 26 / macOS 26, system controls, presentations and toolbars animate themselves.
  Adding your own `withAnimation` around a navigation or sheet state change fights the
  system transition; let it run and animate only your own content.
- SF Symbols animate through `.symbolEffect(_:options:value:)` — `.bounce`, `.pulse`,
  `.wiggle`, `.breathe` — and change glyph through `.contentTransition(.symbolEffect)`.
  Do not rebuild these by hand with rotation and scale.
- Numeric text changing in place wants `.contentTransition(.numericText(value:))`, which
  rolls digits instead of cross-fading them. `.numericText(countsDown:)` for a countdown.
- macOS respects Reduce Motion too, and pointer-driven hover states should animate faster
  (~0.15s) than touch-driven ones.

## Pitfalls

- **Animation modifiers inside an `if` are removed with the view.** Nothing animates on
  removal. The animation must be on an ancestor that survives, or in `withAnimation`.
- **The nearest implicit animation wins.** An `.animation(_:value:)` further out in the
  tree overrides the `withAnimation` that triggered the change. That is the usual cause of
  "my `withAnimation` curve is being ignored".
- **A changed `.id` is not an animation.** It destroys and recreates the view; the old
  value is gone, so there is nothing to interpolate from.
- **Animating a `GeometryReader`-derived value lags a frame**, because the read happens
  during layout of the already-animating frame. Derive from state instead.
- **`.animation(.linear(duration: 0), value:)` is not "no animation".** Use
  `.transaction { $0.animation = nil }` — see **view/animation-advanced**.
- **`@State` reset in `onAppear` animates from the initial value** if an implicit
  animation is in scope. Set it before the first render or wrap in a disabled transaction.
