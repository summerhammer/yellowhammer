# Gestures

Recognising touch, pointer and trackpad input: tap, drag, magnify, rotate, and combining
them. Companion to **view/animation** (animating what a gesture drives) and
**view/scroll-patterns** (scroll-driven effects, which are not gestures).

## Use a control first

`Button`, `Toggle`, `Menu`, `.swipeActions`, `.contextMenu` and `.draggable` already carry
hit-testing, accessibility, hover, keyboard activation and the platform's press feedback.
A hand-rolled `onTapGesture` carries none of it and is invisible to VoiceOver as a control.

| Want | Use |
|---|---|
| Activation | `Button` — never `onTapGesture` |
| Long press to reveal actions | `.contextMenu` |
| Row swipe | `.swipeActions` |
| Move data between views/apps | `.draggable` / `.dropDestination` |
| Tap where the user touched, or a double tap | `onTapGesture(count:coordinateSpace:)` |
| Continuous, value-producing input | a `Gesture` (below) |

## The gestures

| Gesture | Value | Notes |
|---|---|---|
| `TapGesture(count:)` | — | `.onTapGesture` is the shorthand |
| `SpatialTapGesture(count:coordinateSpace:)` | `location` | tap location without a coordinate-space read |
| `LongPressGesture(minimumDuration:maximumDistance:)` | `Bool` | `.onLongPressGesture(perform:onPressingChanged:)` for press-in feedback |
| `DragGesture(minimumDistance:coordinateSpace:)` | `translation`, `location`, `velocity`, `predictedEndTranslation` | `minimumDistance: 0` to track from touch-down |
| `MagnifyGesture(minimumScaleDelta:)` | `magnification`, `startAnchor` | pinch; `MagnificationGesture` is deprecated |
| `RotateGesture(minimumAngleDelta:)` | `rotation: Angle` | `RotationGesture` is deprecated |

All are relative to the gesture's start: `magnification` is `1.0` at the start, not the
view's current scale, and `translation` is `.zero`. Keep a committed `@State` value and
compose it with the in-flight one.

## `@GestureState` for in-flight values

```swift
@GestureState private var drag: CGSize = .zero
@State private var offset: CGSize = .zero

Card()
    .offset(x: offset.width + drag.width, y: offset.height + drag.height)
    .gesture(
        DragGesture()
            .updating($drag) { value, state, _ in state = value.translation }
            .onEnded { value in offset += value.translation }
    )
```

- `@GestureState` **resets itself to the initial value automatically** when the gesture
  ends or is cancelled — the whole point of it. Plain `@State` mutated in `onChanged`
  strands the view mid-drag when the system cancels the gesture (a call, a notification, a
  parent scroll claiming the touch).
- `updating` is for the transient part, `onEnded` for the committed part. Never write the
  committed value from `onChanged`.
- `onEnded` is not guaranteed to run. Anything that must happen on release (haptics, a
  network write) still needs a cancelled path.

## Combining gestures

| Relationship | Operator | Typical use |
|---|---|---|
| Both at once | `.simultaneously(with:)` | pinch **and** rotate a photo |
| One then the other | `.sequenced(before:)` | long press to pick up, then drag |
| First to win | `.exclusively(before:)` | double tap beats single tap |

Combined values are nested enums (`.first`, `.second`) or a struct of two optionals.
Switch over them into one app-level enum rather than reading them at the use site — see
Apple's `DragState` pattern in *Composing SwiftUI gestures*.

```swift
.gesture(MagnifyGesture().simultaneously(with: RotateGesture()))
```

## Attaching

- `.gesture(_:)` — lower priority than gestures inside the view (a `Button` still wins).
- `.highPriorityGesture(_:)` — beats the subviews'. Use sparingly; it silently kills
  buttons and links underneath.
- `.simultaneousGesture(_:)` — runs alongside the subviews' instead of competing.
- `.gesture(_:isEnabled:)` — disable conditionally without rebuilding the modifier chain.
  Prefer it to wrapping the whole `.gesture` in an `if`, which changes view identity.
- `.gesture(_:name:isEnabled:)` and `GestureInputKinds` (`.directTouch`, `.pointer`,
  `.pencil`, `.indirectTouch`) let a gesture respond to only some input kinds — keep a
  trackpad-only affordance from firing on touch.
- `GestureMask` (`.all`, `.gesture`, `.subviews`, `.none`) is the blunt version of the
  above when you must disable subview gestures wholesale.

## Rules

- **One source of truth per interaction.** Derive offset, scale and opacity from the
  gesture value; parallel booleans drift when the gesture is interrupted.
- **Do not animate every frame.** `onChanged`/`updating` fire continuously; a
  `withAnimation` inside stacks hundreds of overlapping animations. Set the value directly
  and animate only the settle in `onEnded`.
- **Use `velocity` / `predictedEndTranslation` for flings**, not a distance threshold — a
  fast short swipe should dismiss, a slow long one should not.
- **Clamp and rubber-band at the edges** rather than letting content leave its bounds.
- **Respect the ~44pt target** and give small draggables `.contentShape(Rectangle())`;
  hit-testing follows drawn content, so transparent padding is not tappable.
- **Gestures are not accessible on their own.** Add `.accessibilityAction`,
  `.accessibilityAdjustableAction` or an alternative control — VoiceOver and Switch
  Control cannot perform a pinch. See **system/accessibility**.
- **Confirm with haptics** on commit, not on every change. See **system/haptic**.

## Pitfalls

- **A `DragGesture` inside a `ScrollView` fights the scroll.** Give it a non-zero
  `minimumDistance`, or prefer scroll-driven state (**view/scroll-patterns**) over a
  custom gesture.
- **`minimumDistance: 0` makes a drag win over a `Button` underneath.** Use
  `.simultaneousGesture` or move the gesture off the button's ancestor.
- **`coordinateSpace` defaults to `.local`**, which moves with the view you are offsetting
  — feeding `location` back into that offset oscillates. Use `.named(_:)` or `.global`.
- **`magnification` is a factor, `rotation` is an `Angle`.** Multiply the committed scale,
  add the committed angle; mixing them up is the usual cause of a photo snapping on the
  second pinch.
- **Gesture modifiers inside an `if` lose in-flight state** when the branch changes. Use
  `isEnabled:` instead.
- **macOS:** pinch and rotate arrive from the trackpad and require no special handling, but
  a hover affordance (`.onHover`) is expected alongside any drag target, and a
  right-click should open a `.contextMenu` rather than a long press.
