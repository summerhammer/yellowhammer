# Haptics

Feedback that the user *feels*. Companion to **view/animation** (the visual half of the
same moment) and **system/capabilities** (hardware that may not be there).

**Use `.sensoryFeedback(_:trigger:)`.** It is the SwiftUI API for haptics on iOS 17+ /
macOS 14+ and it replaces `UIImpactFeedbackGenerator`, `UISelectionFeedbackGenerator` and
`UINotificationFeedbackGenerator` outright. Reach for UIKit generators only for the one
case below.

## Attach to state, not to actions

A haptic belongs on the view that owns the state change, declared once:

```swift
struct CartButton: View {
    @State private var itemCount = 0

    var body: some View {
        Button("Add") { itemCount += 1 }
            .sensoryFeedback(.increase, trigger: itemCount)
    }
}
```

Not this:

```swift
Button("Add") {
    itemCount += 1
    UIImpactFeedbackGenerator(style: .light).impactOccurred()  // ✗
}
```

The difference is not style. `trigger:` fires on *any* change to the value, so the
feedback follows the state when it is also mutated by a swipe action, a `.refreshable`, a
deep link or a push — the imperative version only covers the one call site you remembered.
It also prepares the engine, throttles repeats, and respects the system settings that
silence haptics for free. No `HapticManager`, no singleton, no `isEnabled` flag threaded
through the view tree.

## Picking a feedback

Name the *meaning*, not the intensity — the system maps meaning to hardware.

| Moment | Use |
|---|---|
| Task finished / failed / dubious | `.success`, `.error`, `.warning` |
| Picker, segmented control, value scrubbing | `.selection` |
| Crossed a meaningful threshold | `.increase`, `.decrease` |
| Long operation began / ended | `.start`, `.stop` |
| Drag snapped to a guide | `.alignment` |
| Discrete detents (a slider with stops) | `.levelChange` |
| A drawn path was recognised | `.pathComplete` *(iOS 26+)* |
| Object landed, collided, was dropped | `.impact(weight:intensity:)` or `.impact(flexibility:intensity:)` |

`.impact` is the escape hatch for a physical metaphor with no semantic name. Everything
else should have one; an app built entirely out of `.impact(weight: .light)` is the old
UIKit habit wearing a new API.

On iOS 26+, controls you build yourself can borrow the system's own control feedback —
`.press(.button)`, `.press(.toggle)`, `.press(.slider)`, `.press(.tab)`,
`.press(.buttonIconOnly)`, the matching `.release(_:)`, and `.selection(_:)`. Prefer these
in a custom `ButtonStyle` or `ToggleStyle` over hand-tuned impacts, so a custom control
feels identical to a stock one.

## The three overloads

```swift
// 1. Always, on every change.
.sensoryFeedback(.selection, trigger: selectedTab)

// 2. Conditionally — same trigger, feedback only when the condition holds.
.sensoryFeedback(.success, trigger: saveCount, condition: { _, _ in !isBatchImport })

// 3. Derived — choose the feedback from the transition, or return nil for silence.
.sensoryFeedback(trigger: phase) { old, new in
    switch new {
    case .succeeded: .success
    case .failed:    .error
    default:         nil
    }
}
```

Overload 3 is the one to reach for with an enum-shaped state machine: one modifier covers
every outcome, and `nil` is how a transition stays silent.

## Platform behaviour

Target the latest iOS and macOS and write one call site for both.

- **iOS/iPadOS** — full haptics on iPhone. iPad has no Taptic Engine; the call is a no-op.
- **macOS 14+** — compiles and is a no-op except on a Force Touch trackpad, where it
  reaches the trackpad. In practice only `.alignment` and `.levelChange` are meaningful
  there, so a Mac-first interaction (dragging in a canvas, a snapping inspector) is where
  the modifier earns its place.

There is **no capability check to write**. `.sensoryFeedback` is safe on hardware that
cannot play it and on a system where the user has turned haptics off — it simply does
nothing. Do not branch on device model, and never make behaviour conditional on whether a
haptic played.

## When UIKit generators are still correct

One case: **continuous or custom-authored haptics** — a waveform that tracks a drag, a
composed pattern with its own envelope. That is Core Haptics (`CHHapticEngine`), not
`sensoryFeedback`, and it needs its own lifecycle (engine start, `.stoppedHandler`,
restart after an interruption). `UIFeedbackGenerator` subclasses have no remaining role in
a SwiftUI view — if one appears in a diff, it is a port that wasn't finished.

## Pitfalls

- **Don't fire haptics on every interaction.** The budget is roughly: confirmations,
  destructive actions, threshold crossings, and selection in a control the user scrubs.
  Everything else is noise, and noise trains people to disable the feature.
- **Don't add an in-app "haptics" toggle** before checking whether the system setting is
  enough — it usually is, and `sensoryFeedback` already honours it.
- **Don't drive the trigger from a value that changes more than the moment does.** Trigger
  on a discrete selection or a counter, never on a continuously-updating drag offset.
- **Don't stack two modifiers on the same trigger value**; use the derived overload and
  return one feedback.
- **`trigger:` needs `Equatable`**, and it fires on *change* — a value reset to the same
  thing plays nothing. For "same action twice in a row", trigger on a counter you
  increment, not on the action's result.
- **Haptics don't play in the SwiftUI preview canvas or the Simulator.** Verifying one
  requires a device.
