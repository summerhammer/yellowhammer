# Animation (advanced)

Multi-step sequences, the transaction system underneath every animation, and making your
own types interpolate. The everyday rules — where to put `.animation`, spring choice,
what not to animate — live in **view/animation**; read that first.

| Want | Use |
|---|---|
| A fixed sequence of discrete steps, one animation each | `.phaseAnimator` |
| Several properties on independent timelines, exact timings | `.keyframeAnimator` |
| Continuous motion driven by time, not by state | `TimelineView` |
| Run code after an animation settles | `withAnimation(_:completion:)` |
| Change or suppress an animation a parent chose | `.transaction` |
| A custom `Shape` or `ViewModifier` that interpolates | `@Animatable` |

## Phase animations

Steps through the phases you give it, animating each hop. With a `trigger:` it runs the
sequence once per change; without one it loops forever.

```swift
enum Shake: CaseIterable {
    case rest, left, right
    var offset: CGFloat {
        switch self { case .rest: 0; case .left: -8; case .right: 8 }
    }
}

Label("Wrong PIN", systemImage: "lock")
    .phaseAnimator(Shake.allCases, trigger: attempts) { view, phase in
        view.offset(x: phase.offset)
    } animation: { phase in
        phase == .rest ? .spring(duration: 0.3) : .snappy(duration: 0.1)
    }
```

Use an enum rather than raw numbers: the phase names the *state*, the computed properties
name the values, and the `animation:` closure can branch on something readable. Phases are
the correct replacement for chains of `DispatchQueue.asyncAfter` — those drift, cannot be
interrupted, and keep running after the view is gone.

## Keyframe animations

For motion where properties need their *own* timelines — a bell that rotates for 0.5s
while scaling for 0.25s. Tracks run in parallel over one value struct.

```swift
struct BellMotion { var rotation = 0.0; var scale = 1.0 }

Image(systemName: "bell.fill")
    .keyframeAnimator(initialValue: BellMotion(), trigger: newAlerts) { view, value in
        view.rotationEffect(.degrees(value.rotation)).scaleEffect(value.scale)
    } keyframes: { _ in
        KeyframeTrack(\.rotation) {
            CubicKeyframe(15, duration: 0.1)
            CubicKeyframe(-15, duration: 0.1)
            CubicKeyframe(0, duration: 0.3)
        }
        KeyframeTrack(\.scale) {
            SpringKeyframe(1.15, duration: 0.25)
            SpringKeyframe(1.0, duration: 0.25)
        }
    }
```

`LinearKeyframe`, `CubicKeyframe` (smooth, the default choice), `SpringKeyframe` and
`MoveKeyframe` (an instant jump, no interpolation). Each keyframe's `duration` is the time
*to reach* it, so a track's total is the sum of its durations — tracks of different
lengths simply finish at different moments.

`KeyframeTimeline` wraps the same tracks outside a view, so you can assert on
`timeline.value(time:)` in a unit test or drive something that is not a SwiftUI view.

**Phase or keyframe?** Phases if each step is a state you could name and the timing is
"whatever a spring does"; keyframes if the design specifies seconds, or properties need
to diverge. Phases are cheaper to read and far cheaper to change.

## Transactions

Every animation travels down the view tree in a `Transaction`. `withAnimation(a) { … }` is
`withTransaction(Transaction(animation: a)) { … }`; `.animation(_:value:)` rewrites the
transaction as it passes. Reach for the transaction API when you need to *inspect* or
*veto* what an ancestor decided.

```swift
// Suppress an animation a parent applied to everything.
Text(count.formatted())
    .transaction { $0.animation = nil }

// Refuse to let descendants override this animation.
DetailView()
    .transaction { $0.disablesAnimations = true }
```

`.transaction { … }` with no `value:` runs on *every* update — the same hazard as the
deprecated `.animation(_:)`. Prefer `.transaction(value:_:)` so it applies only when that
value changes.

A `TransactionKey` carries your own metadata alongside the animation, which lets a view
animate differently depending on *why* it changed — a user edit versus a server push —
without threading a flag through every intermediate view.

```swift
struct SourceKey: TransactionKey { static let defaultValue = "local" }
extension Transaction {
    var source: String {
        get { self[SourceKey.self] } set { self[SourceKey.self] = newValue }
    }
}
```

## Completion

```swift
withAnimation(.snappy) { isExpanded = true } completion: { hasSettled = true }
```

The handler fires when the animation finishes *or* is removed, so treat it as "no longer
running", not "arrived at the target". For a completion that refires on each change of a
value, use `.transaction(value:)` and `addAnimationCompletion` — a bare `.transaction`
registers the handler once, and it then fires only once, which is a silent and very
confusing bug.

Do not sequence UI by chaining completions. Two states that must move in order are a
phase animation; a completion is for side effects (haptics, a log, dismissing) after
motion ends.

## Making a type animatable

SwiftUI can only interpolate `VectorArithmetic`. A custom `Shape` or `ViewModifier` whose
stored properties drive drawing must expose them as `animatableData`, or the change snaps
to its final value with no error.

`@Animatable` synthesises that from the stored properties; `@AnimatableIgnored` excludes
the ones that select behaviour rather than measure it.

```swift
@Animatable
struct Wedge: Shape {
    var startAngle: Angle
    var endAngle: Angle
    @AnimatableIgnored var clockwise: Bool

    func path(in rect: CGRect) -> Path { /* … */ }
}
```

Write `animatableData` by hand only when the interpolated value needs logic — clamping,
wrapping a phase into `0..<2π`, deriving one property from another. Use
`AnimatableValues` for several values; nested `AnimatablePair` is the older, far less
readable spelling of the same thing.

```swift
struct Wave: Shape {
    var amplitude: CGFloat
    var phase: CGFloat

    var animatableData: AnimatableValues<CGFloat, CGFloat> {
        get { AnimatableValues(amplitude, phase) }
        set {
            amplitude = max(0, newValue.value.0)
            phase = newValue.value.1.truncatingRemainder(dividingBy: 2 * .pi)
        }
    }

    func path(in rect: CGRect) -> Path { /* … */ }
}
```

## Time-driven motion

`TimelineView(.animation)` re-evaluates its body on the display's schedule and hands you a
date — for motion that depends on *time* rather than state (a pulsing indicator, a shader
clock, a progress ring driven by a deadline). It is not an animation: nothing interpolates
and nothing is interruptible; you compute each frame. That makes it the wrong tool for
anything a state change could drive, and the only tool for a continuously running effect.

Pair with `.paused` when off-screen — a running timeline keeps the view redrawing and the
device awake.

## Pitfalls

- A `phaseAnimator` with no `trigger:` never stops. Give it a trigger, or make sure the
  view is removed when the motion should end.
- Keyframe tracks interpolate a *struct you own*; adding a property with a non-zero
  default and no track leaves it pinned at that default, silently.
- `.transaction` applies to the whole subtree below it, including presentations and
  navigation destinations that draw their own transitions.
- `@Animatable` on a type with a non-animatable stored property is a compile error, not a
  warning to ignore — annotate it `@AnimatableIgnored`.
- Interpolating an angle across the 0/2π boundary walks the long way round. Normalise in
  the `animatableData` setter, or animate a continuous value and take the remainder when
  drawing.
